#include <assert.h>
#include <pcap.h>
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>
#include "OfflinePcap.h"
#include "wm_pcap.h"

struct pcap { int open; int nonblocking; pcap_direction_t direction; };
static struct pcap handles[64];
static uint8_t requests[64][60];
static uint8_t frames[1024][60];
static struct pcap_pkthdr header;
static int request_count, request_index, frame_count, opens, closes;
static int inject_result = 60;
static int read_failure, nonblock_failure, filter_failure;
static int direction_failure, outgoing[64];
static int open_failure;

void offline_reset(void) {
    assert(opens == closes);
    request_count = request_index = frame_count = opens = closes = 0;
    inject_result = 60;
    read_failure = nonblock_failure = filter_failure = 0;
    direction_failure = 0;
    open_failure = 0;
    memset(outgoing, 0, sizeof(outgoing));
    memset(handles, 0, sizeof(handles));
}
int offline_frame_count(void) { return frame_count; }
int offline_open_count(void) { return opens; }
int offline_close_count(void) { return closes; }
void offline_set_inject_result(int result) { inject_result = result; }
void offline_set_read_failure(int failure) { read_failure = failure; }
void offline_set_nonblock_failure(int failure) { nonblock_failure = failure; }
void offline_set_filter_failure(int failure) { filter_failure = failure; }
void offline_set_direction_failure(int failure) { direction_failure = failure; }
void offline_set_open_failure(int failure) { open_failure = failure; }
int offline_frame_byte(int index, int offset) {
    assert(index >= 0 && index < frame_count && offset >= 0 && offset < 60);
    return frames[index][offset];
}
int offline_broadcast_count(void) {
    int count = 0;
    for (int i = 0; i < frame_count; i++) count += (frames[i][0] & 1) != 0;
    return count;
}

/* Construct requests independently of the production packet builder. */
void offline_enqueue(const uint8_t mac[6], const char *ip, const char *asked_ip) {
    assert(request_count < 64);
    uint8_t *frame = requests[request_count++];
    memset(frame, 0, 60);
    memset(frame, 0xff, 6);
    memcpy(frame + 6, mac, 6);
    frame[12] = 0x08; frame[13] = 0x06;
    frame[15] = 1; frame[16] = 0x08;
    frame[18] = 6; frame[19] = 4; frame[21] = 1;
    memcpy(frame + 22, mac, 6);
    assert(inet_pton(AF_INET, ip, frame + 28) == 1);
    assert(inet_pton(AF_INET, asked_ip, frame + 38) == 1);
    header.caplen = header.len = 60;
}

/* Every libpcap function used by wm_arp.c resolves here. Opening any interface
 * except the fixture name aborts, so this harness cannot touch a live network. */
pcap_t *pcap_create(const char *name, char *errbuf) {
    assert(strcmp(name, "offline") == 0 && opens < 64);
    if (open_failure) { strcpy(errbuf, "offline open failure"); return NULL; }
    handles[opens].open = 1;
    return &handles[opens++];
}
int pcap_set_snaplen(pcap_t *p, int n) { (void)n; assert(p->open); return 0; }
int pcap_set_promisc(pcap_t *p, int n) { (void)n; assert(p->open); return 0; }
int pcap_set_timeout(pcap_t *p, int n) { (void)n; assert(p->open); return 0; }
int pcap_set_immediate_mode(pcap_t *p, int n) { (void)n; assert(p->open); return 0; }
int pcap_activate(pcap_t *p) { assert(p->open); return 0; }
int pcap_setnonblock(pcap_t *p, int nonblocking, char *errbuf) {
    assert(p->open && nonblocking == 1);
    if (nonblock_failure) { strcpy(errbuf, "offline nonblock failure"); return -1; }
    p->nonblocking = nonblocking; return 0;
}
int pcap_setdirection(pcap_t *p, pcap_direction_t direction) {
    assert(p->open);
    if (direction_failure) return -1;
    p->direction = direction; return 0;
}
int pcap_compile(pcap_t *p, struct bpf_program *program, const char *filter,
                 int optimize, bpf_u_int32 mask) {
    (void)program; (void)filter; (void)optimize; (void)mask;
    assert(p->open); return 0;
}
int pcap_setfilter(pcap_t *p, struct bpf_program *program) {
    (void)program; assert(p->open); return filter_failure ? -1 : 0;
}
void pcap_freecode(struct bpf_program *program) { (void)program; }
void pcap_close(pcap_t *p) { assert(p->open); p->open = 0; closes++; }
char *pcap_geterr(pcap_t *p) { assert(p->open); return "offline fixture failure"; }
int pcap_inject(pcap_t *p, const void *data, size_t size) {
    assert(p->open && size == 60 && frame_count < 1024);
    memcpy(frames[frame_count++], data, size);
    return inject_result;
}
int pcap_next_ex(pcap_t *p, struct pcap_pkthdr **hdr, const u_char **data) {
    assert(p->open && p->nonblocking);
    if (read_failure) return -1;
    while (request_index < request_count && outgoing[request_index]
           && p->direction == PCAP_D_IN) request_index++;
    if (request_index >= request_count) return 0;
    *hdr = &header; *data = requests[request_index++]; return 1;
}
int pcap_dispatch(pcap_t *p, int count, pcap_handler handler, u_char *user) {
    int delivered = 0;
    for (int i = 0; i < count; i++) {
        struct pcap_pkthdr *hdr;
        const u_char *data;
        int result = pcap_next_ex(p, &hdr, &data);
        if (result <= 0) return result < 0 ? result : delivered;
        handler(user, hdr, data); delivered++;
    }
    return delivered;
}

#ifndef PACKET_SAFETY_SWIFT_SUPPORT
static const uint8_t own_mac[6] = {2, 0, 0, 0, 0, 10};
static const uint8_t own_ip[4] = {192, 168, 1, 10};
static const uint8_t gateway_mac[6] = {2, 0, 0, 0, 0, 1};
static const uint8_t gateway_ip[4] = {192, 168, 1, 1};
static const uint8_t selected_mac[6] = {2, 0, 0, 0, 0, 20};
static const uint8_t selected_ip[4] = {192, 168, 1, 20};
static const uint8_t trusted_mac[6] = {2, 0, 0, 0, 0, 30};
static const uint8_t zero_mac[6] = {0};
static const uint8_t multicast_mac[6] = {1, 0, 0, 0, 0, 1};

static int pump(void *handle, const uint8_t *ips, const uint8_t *macs, int count) {
    return wm_arp_resp_pump(handle, own_mac, own_ip, gateway_mac, gateway_ip,
                            ips, macs, count, 256);
}
static void expect_request(void *handle, const uint8_t *mac, const char *ip,
                           const char *asked_ip, int expected) {
    request_count = request_index = 0;
    offline_enqueue(mac, ip, asked_ip);
    int before = frame_count;
    assert(pump(handle, selected_ip, selected_mac, 1) == expected);
    assert(frame_count == before + expected);
    if (expected) {
        assert(memcmp(frames[before], mac, 6) == 0);
        assert(memcmp(frames[before] + 6, own_mac, 6) == 0);
        assert(frames[before][21] == 2);
    }
}

int main(void) {
    char errbuf[256];
    void *handle = wm_arp_resp_open("offline", errbuf);
    assert(handle);
    expect_request(handle, selected_mac, "192.168.1.20", "192.168.1.1", 1);
    expect_request(handle, gateway_mac, "192.168.1.1", "192.168.1.20", 1);
    expect_request(handle, own_mac, "192.168.1.10", "192.168.1.1", 0);
    expect_request(handle, trusted_mac, "192.168.1.30", "192.168.1.1", 0);
    expect_request(handle, trusted_mac, "192.168.1.30", "192.168.1.20", 0);
    expect_request(handle, selected_mac, "192.168.1.30", "192.168.1.1", 0);
    expect_request(handle, trusted_mac, "192.168.1.20", "192.168.1.1", 0);
    expect_request(handle, selected_mac, "192.168.1.20", "192.168.1.30", 0);
    expect_request(handle, gateway_mac, "192.168.1.1", "192.168.1.30", 0);
    expect_request(handle, trusted_mac, "192.168.1.1", "192.168.1.20", 0);
    expect_request(handle, gateway_mac, "192.168.1.30", "192.168.1.20", 0);
    expect_request(handle, selected_mac, "192.168.1.10", "192.168.1.1", 0);
    expect_request(handle, own_mac, "192.168.1.20", "192.168.1.1", 0);
    expect_request(handle, zero_mac, "192.168.1.20", "192.168.1.1", 0);
    expect_request(handle, multicast_mac, "192.168.1.20", "192.168.1.1", 0);

    int before = frame_count;
    request_count = request_index = 0;
    offline_enqueue(selected_mac, "192.168.1.20", "192.168.1.1");
    assert(pump(handle, NULL, NULL, 0) == 0 && request_index == 0);
    assert(pump(handle, own_ip, own_mac, 1) == 0);
    request_index = 0;
    assert(pump(handle, gateway_ip, gateway_mac, 1) == 0);
    assert(frame_count == before);

    /* Corrupted Ethernet/ARP identity or protocol fields must never reply. */
    const int fields[] = {6, 12, 15, 16, 18, 19, 21, 22, 28, 38};
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
        request_count = request_index = 0;
        offline_enqueue(selected_mac, "192.168.1.20", "192.168.1.1");
        requests[0][fields[i]] ^= 0x10;
        assert(pump(handle, selected_ip, selected_mac, 1) == 0);
    }
    request_count = request_index = 0;
    offline_enqueue(selected_mac, "192.168.1.20", "192.168.1.1");
    header.caplen = 41;
    assert(pump(handle, selected_ip, selected_mac, 1) == 0);
    header.caplen = 60;

    /* The restoration wire frames repair each legitimate peer binding. */
    before = frame_count;
    assert(wm_arp_send_restore(handle, gateway_mac, selected_mac,
                               "192.168.1.20", "192.168.1.1") == 0);
    assert(wm_arp_send_restore(handle, selected_mac, gateway_mac,
                               "192.168.1.1", "192.168.1.20") == 0);
    assert(memcmp(frames[before], selected_mac, 6) == 0);
    assert(memcmp(frames[before] + 22, gateway_mac, 6) == 0);
    assert(memcmp(frames[before] + 28, gateway_ip, 4) == 0);
    assert(memcmp(frames[before + 1], gateway_mac, 6) == 0);
    assert(memcmp(frames[before + 1] + 22, selected_mac, 6) == 0);
    assert(memcmp(frames[before + 1] + 28, selected_ip, 4) == 0);

    before = frame_count;
    assert(wm_arp_send_spoof(handle, own_mac, multicast_mac,
                             "192.168.1.20", "192.168.1.1") == -1);
    assert(wm_arp_send_restore(handle, gateway_mac, zero_mac,
                               "192.168.1.20", "192.168.1.1") == -1);
    assert(wm_arp_send_restore(handle, gateway_mac, selected_mac,
                               "bad address", "192.168.1.1") == -1);
    assert(wm_arp_send_spoof(handle, own_mac, selected_mac,
                             "192.168.1.20", "224.0.0.1") == -1);
    assert(frame_count == before);
    inject_result = 59;
    assert(wm_arp_send_restore(handle, gateway_mac, selected_mac,
                               "192.168.1.20", "192.168.1.1") == -1);
    assert(offline_broadcast_count() == 0);
    wm_arp_resp_close(handle);
    assert(opens == closes);

    offline_reset();
    offline_set_nonblock_failure(1);
    assert(wm_arp_resp_open("offline", errbuf) == NULL);
    assert(opens == closes && frame_count == 0);
    offline_reset();
    offline_set_filter_failure(1);
    assert(wm_arp_resp_open("offline", errbuf) == NULL);
    assert(opens == closes && frame_count == 0);
    offline_reset();
    handle = wm_arp_resp_open("offline", errbuf);
    offline_set_read_failure(1);
    assert(pump(handle, selected_ip, selected_mac, 1) == -1);
    offline_set_read_failure(0);
    offline_enqueue(selected_mac, "192.168.1.20", "192.168.1.1");
    offline_set_inject_result(-1);
    assert(pump(handle, selected_ip, selected_mac, 1) == -1);
    wm_arp_resp_close(handle);
    assert(opens == closes && offline_broadcast_count() == 0);

    /* Locally injected bindings must not feed back into scanner inventory. */
    offline_reset();
    wm_arp_observation_t observations[8] = {0};
    offline_enqueue(own_mac, "192.168.1.20", "192.168.1.10");
    requests[0][21] = 2; outgoing[0] = 1;
    offline_enqueue(trusted_mac, "192.168.1.20", "192.168.1.10");
    requests[1][21] = 2;
    offline_enqueue(selected_mac, "192.168.1.21", "192.168.1.10");
    requests[2][21] = 2; requests[2][18] = 5;
    assert(wm_pcap_capture_arp("offline", 1, observations, 8, errbuf) == 1);
    assert(strcmp(observations[0].ip, "192.168.1.20") == 0);
    assert(memcmp(observations[0].mac, trusted_mac, 6) == 0);
    assert(opens == closes);

    offline_reset();
    offline_enqueue(selected_mac, "192.168.1.20", "192.168.1.10");
    requests[0][21] = 2;
    offline_enqueue(trusted_mac, "192.168.1.20", "192.168.1.10");
    requests[1][21] = 2;
    assert(wm_pcap_capture_arp("offline", 1, observations, 8, errbuf) == 2);
    assert(memcmp(observations[0].mac, observations[1].mac, 6) != 0);
    assert(opens == closes);

    offline_reset();
    offline_set_direction_failure(1);
    assert(wm_pcap_capture_arp("offline", 1, observations, 8, errbuf) == -1);
    assert(opens == closes);
    puts("Packet C safety passed: scoped pairs, trusted/self protection, malformed frames, unicast restoration, runtime faults, nonblocking setup, inbound-only scanner, and conflicting bindings");
    return 0;
}
#endif
