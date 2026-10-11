#ifndef WM_PCAP_H
#define WM_PCAP_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- live ARP capture for scanner ---- */
typedef struct {
    char     ip[40];
    uint8_t  mac[6];
} wm_arp_observation_t;

/* Capture ARP replies on `iface` for `duration_ms`, fill out_buf with up to max_count obs.
 * Returns number of observations captured.
 */
int wm_pcap_capture_arp(const char *iface,
                        int duration_ms,
                        wm_arp_observation_t *out_buf,
                        int max_count,
                        char *errbuf /* >=256 */);

/* ---- per-MAC traffic counter ---- */
typedef struct wm_traffic_ctx wm_traffic_ctx;

wm_traffic_ctx *wm_traffic_open(const char *iface, char *errbuf /* >=256 */);
void wm_traffic_close(wm_traffic_ctx *ctx);

/* Pump a non-blocking batch of packets (call ~10x/sec). */
int wm_traffic_pump(wm_traffic_ctx *ctx, int max_packets);

/* Read & reset per-MAC byte counter. Caller passes parallel arrays length n.
 * Returns number of MACs filled.
 */
int wm_traffic_drain(wm_traffic_ctx *ctx,
                     uint8_t macs_out[][6],
                     uint64_t bytes_out[],
                     int n);

#ifdef __cplusplus
}
#endif
#endif
