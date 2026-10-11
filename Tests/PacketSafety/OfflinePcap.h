#ifndef OFFLINE_PCAP_H
#define OFFLINE_PCAP_H

#include "wm_arp.h"
#include "wm_pcap.h"

/* Test-only pcap implementations. No real libpcap is linked by the runner. */
void offline_reset(void);
int offline_frame_count(void);
int offline_frame_byte(int index, int offset);
int offline_broadcast_count(void);
int offline_open_count(void);
int offline_close_count(void);
void offline_enqueue(const uint8_t mac[6], const char *ip, const char *asked_ip);
void offline_set_inject_result(int result);
void offline_set_read_failure(int failure);
void offline_set_nonblock_failure(int failure);
void offline_set_filter_failure(int failure);
void offline_set_direction_failure(int failure);
void offline_set_open_failure(int failure);

#endif
