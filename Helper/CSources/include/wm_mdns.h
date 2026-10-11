#ifndef WM_MDNS_H
#define WM_MDNS_H

#include <stdint.h>
#include <stdbool.h>
#include <dispatch/dispatch.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Fired once per discovered service instance, AFTER an internal resolve
/// has produced TXT and the host:port pair. Strings are null-terminated.
/// `txt_data` is the on-the-wire TXT record bytes (length-prefixed entries);
/// pass to `wm_mdns_txt_iterate` to walk it.
typedef void (*wm_mdns_event_cb)(
    const char* service_type,
    const char* instance_name,
    const char* host_target,
    uint16_t port,
    uint16_t txt_len,
    const uint8_t* txt_data,
    void* user
);

/// Begin a continuous browse on `type` (e.g. "_airplay._tcp"). Each Add
/// triggers an internal resolve; the resolve's TXT result is delivered via
/// `cb`. `events_queue` may be NULL (a private serial queue is created).
/// Returns NULL on error. Returned handle is opaque; pass to wm_mdns_close.
void* wm_mdns_open(const char* type,
                   wm_mdns_event_cb cb,
                   void* user,
                   dispatch_queue_t events_queue);

/// Stop browsing and release all resources held by the context.
void wm_mdns_close(void* ctx);

/// Walk a TXT record. The TXT format is a sequence of length-prefixed
/// `key=value` strings; this helper parses them and fires `cb` for each
/// pair with null-terminated key/value buffers.
typedef void (*wm_mdns_txt_iter_cb)(const char* key, const char* value, void* user);
void wm_mdns_txt_iterate(uint16_t txt_len,
                         const uint8_t* txt_data,
                         wm_mdns_txt_iter_cb cb,
                         void* user);

#ifdef __cplusplus
}
#endif

#endif /* WM_MDNS_H */
