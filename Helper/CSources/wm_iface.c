#include "wm_iface.h"

#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

/* macOS struct for SIOCAIFADDR: in_aliasreq from <netinet/in_var.h>.
 * We declare the layout locally to avoid pulling the entire netinet/in_var
 * header chain (which has BSD-internal bits). The ABI for in_aliasreq is
 * stable on macOS — it's been the same since 10.x. */
struct wm_in_aliasreq {
    char            ifra_name[16];
    struct sockaddr_in ifra_addr;
    struct sockaddr_in ifra_broadaddr;
    struct sockaddr_in ifra_mask;
};

#ifndef SIOCAIFADDR
#define SIOCAIFADDR _IOW('i', 26, struct wm_in_aliasreq)
#endif
#ifndef SIOCDIFADDR
#define SIOCDIFADDR _IOW('i', 25, struct ifreq)
#endif

int wm_iface_add_alias(const char *iface, const char *ipv4) {
    if (!iface || !ipv4) return EINVAL;
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return errno;

    struct wm_in_aliasreq req;
    memset(&req, 0, sizeof(req));
    strncpy(req.ifra_name, iface, sizeof(req.ifra_name) - 1);

    req.ifra_addr.sin_len = sizeof(struct sockaddr_in);
    req.ifra_addr.sin_family = AF_INET;
    if (inet_pton(AF_INET, ipv4, &req.ifra_addr.sin_addr) != 1) {
        close(s); return EINVAL;
    }

    /* Host route — netmask 255.255.255.255 — so we don't disturb the existing
     * subnet routing for our real IP. The alias is added but not advertised
     * as an additional subnet route. */
    req.ifra_mask.sin_len = sizeof(struct sockaddr_in);
    req.ifra_mask.sin_family = AF_INET;
    req.ifra_mask.sin_addr.s_addr = htonl(0xFFFFFFFFu);

    /* Broadcast address — same as the alias for a /32. */
    req.ifra_broadaddr.sin_len = sizeof(struct sockaddr_in);
    req.ifra_broadaddr.sin_family = AF_INET;
    req.ifra_broadaddr.sin_addr.s_addr = req.ifra_addr.sin_addr.s_addr;

    int rc = ioctl(s, SIOCAIFADDR, &req);
    int saved_errno = (rc < 0) ? errno : 0;
    close(s);
    if (rc < 0) {
        if (saved_errno == EEXIST) return 0;
        return saved_errno;
    }
    return 0;
}

int wm_iface_remove_alias(const char *iface, const char *ipv4) {
    if (!iface || !ipv4) return EINVAL;
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return errno;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, iface, sizeof(ifr.ifr_name) - 1);
    struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
    sin->sin_len = sizeof(struct sockaddr_in);
    sin->sin_family = AF_INET;
    if (inet_pton(AF_INET, ipv4, &sin->sin_addr) != 1) {
        close(s); return EINVAL;
    }

    int rc = ioctl(s, SIOCDIFADDR, &ifr);
    int saved_errno = (rc < 0) ? errno : 0;
    close(s);
    if (rc < 0) {
        if (saved_errno == EADDRNOTAVAIL) return 0;  /* not present, fine */
        return saved_errno;
    }
    return 0;
}
