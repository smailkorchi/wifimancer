// wm_mdns.c
// DNSSD-backed mDNS browser. Replaces a Process+dns-sd pipe approach that
// failed because the macOS dns-sd CLI block-buffers stdout when its
// destination isn't a TTY — under our 12-second test window we never
// accumulated enough output to flush. This C shim talks directly to the
// same mDNSResponder via the public DNSSD API, routes events onto a
// GCD queue, and delivers TXT records inline.

#include "wm_mdns.h"
#include <dns_sd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>
#include <arpa/inet.h>

struct wm_mdns_ctx {
    DNSServiceRef browse_ref;
    char service_type[128];
    wm_mdns_event_cb cb;
    void* user;
    dispatch_queue_t queue;
    bool owns_queue;
    atomic_int closing;
};

// Per-resolve heap context. The Bonjour resolve API keeps the ref alive
// until we deallocate it, so the resolve_ctx must outlive the call too.
typedef struct {
    struct wm_mdns_ctx* parent;
    DNSServiceRef ref;
} resolve_ctx;

static void resolve_cb(DNSServiceRef sdRef,
                       DNSServiceFlags flags,
                       uint32_t interfaceIndex,
                       DNSServiceErrorType errorCode,
                       const char* fullname,
                       const char* hosttarget,
                       uint16_t port,
                       uint16_t txtLen,
                       const unsigned char* txtRecord,
                       void* context) {
    resolve_ctx* rc = (resolve_ctx*)context;
    if (!rc) return;
    if (atomic_load(&rc->parent->closing)) {
        DNSServiceRefDeallocate(rc->ref);
        free(rc);
        return;
    }
    if (errorCode == kDNSServiceErr_NoError && rc->parent->cb) {
        // Extract instance from `<instance>.<type>.<domain>.` — keep it
        // simple: the instance is everything up to the first ".<type>"
        // occurrence. Falls back to fullname if anything goes sideways.
        char instance[256] = {0};
        const char* needle = rc->parent->service_type;
        const char* pos = strstr(fullname, needle);
        if (pos && pos > fullname && *(pos - 1) == '.') {
            size_t n = (size_t)((pos - 1) - fullname);
            if (n >= sizeof(instance)) n = sizeof(instance) - 1;
            memcpy(instance, fullname, n);
        } else {
            strncpy(instance, fullname, sizeof(instance) - 1);
        }
        rc->parent->cb(rc->parent->service_type,
                       instance,
                       hosttarget ? hosttarget : "",
                       ntohs(port),
                       txtLen,
                       (const uint8_t*)txtRecord,
                       rc->parent->user);
    }
    // Resolve is one-shot for our purposes — release immediately so we
    // don't hold mDNSResponder file descriptors for every device on a
    // chatty LAN.
    DNSServiceRefDeallocate(rc->ref);
    free(rc);
}

static void browse_cb(DNSServiceRef sdRef,
                      DNSServiceFlags flags,
                      uint32_t interfaceIndex,
                      DNSServiceErrorType errorCode,
                      const char* serviceName,
                      const char* regtype,
                      const char* replyDomain,
                      void* context) {
    struct wm_mdns_ctx* ctx = (struct wm_mdns_ctx*)context;
    if (!ctx || atomic_load(&ctx->closing)) return;
    if (errorCode != kDNSServiceErr_NoError) return;
    // We only react to Add events; Rmv is handled by the higher-level
    // device-vault expiry rather than by removing TXT we already collected.
    if (!(flags & kDNSServiceFlagsAdd)) return;

    resolve_ctx* rc = (resolve_ctx*)calloc(1, sizeof(*rc));
    if (!rc) return;
    rc->parent = ctx;

    DNSServiceErrorType err = DNSServiceResolve(
        &rc->ref, 0, interfaceIndex,
        serviceName, regtype, replyDomain,
        resolve_cb, rc);
    if (err != kDNSServiceErr_NoError) {
        free(rc);
        return;
    }
    DNSServiceSetDispatchQueue(rc->ref, ctx->queue);
}

void* wm_mdns_open(const char* type,
                   wm_mdns_event_cb cb,
                   void* user,
                   dispatch_queue_t events_queue) {
    if (!type || !cb) return NULL;
    struct wm_mdns_ctx* ctx = (struct wm_mdns_ctx*)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    strncpy(ctx->service_type, type, sizeof(ctx->service_type) - 1);
    ctx->cb = cb;
    ctx->user = user;
    if (events_queue) {
        ctx->queue = events_queue;
        ctx->owns_queue = false;
    } else {
        ctx->queue = dispatch_queue_create("com.wifimancer.mdns", DISPATCH_QUEUE_SERIAL);
        ctx->owns_queue = true;
    }
    atomic_init(&ctx->closing, 0);

    DNSServiceErrorType err = DNSServiceBrowse(
        &ctx->browse_ref, 0, kDNSServiceInterfaceIndexAny,
        type, "local", browse_cb, ctx);
    if (err != kDNSServiceErr_NoError) {
        if (ctx->owns_queue) ctx->queue = NULL;
        free(ctx);
        return NULL;
    }
    DNSServiceSetDispatchQueue(ctx->browse_ref, ctx->queue);
    return ctx;
}

void wm_mdns_close(void* opaque) {
    if (!opaque) return;
    struct wm_mdns_ctx* ctx = (struct wm_mdns_ctx*)opaque;
    atomic_store(&ctx->closing, 1);
    if (ctx->browse_ref) {
        DNSServiceRefDeallocate(ctx->browse_ref);
        ctx->browse_ref = NULL;
    }
    // Pending in-flight resolve_cb invocations after this point hit the
    // closing flag and short-circuit; they were enqueued on ctx->queue and
    // we don't free ctx until those are drained. Easiest correct-in-all-
    // cases fix: dispatch a barrier sync on the queue, then release.
    if (ctx->queue) {
        dispatch_sync(ctx->queue, ^{ /* barrier */ });
    }
    if (ctx->owns_queue) {
        // Auto-released by ARC under -fobjc-arc; nothing to do.
        ctx->queue = NULL;
    }
    free(ctx);
}

void wm_mdns_txt_iterate(uint16_t txt_len,
                         const uint8_t* txt_data,
                         wm_mdns_txt_iter_cb cb,
                         void* user) {
    if (!cb || txt_len == 0 || !txt_data) return;
    uint16_t count = TXTRecordGetCount(txt_len, txt_data);
    for (uint16_t i = 0; i < count; i++) {
        char key[256];
        uint8_t value_len = 0;
        const void* value = NULL;
        DNSServiceErrorType err = TXTRecordGetItemAtIndex(
            txt_len, txt_data, i,
            (uint16_t)sizeof(key), key,
            &value_len, &value);
        if (err != kDNSServiceErr_NoError) continue;
        char value_buf[256];
        size_t copy_len = value_len < sizeof(value_buf) - 1
                          ? value_len
                          : sizeof(value_buf) - 1;
        if (value && copy_len > 0) memcpy(value_buf, value, copy_len);
        value_buf[copy_len] = 0;
        cb(key, value_buf, user);
    }
}
