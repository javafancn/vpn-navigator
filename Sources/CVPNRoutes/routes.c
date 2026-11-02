#include "CVPNRoutes.h"
#include <sys/socket.h>
#include <net/route.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

static int route_sequence;

int vpn_routes_open(void) {
    int fd = socket(PF_ROUTE, SOCK_RAW, 0);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    // route(8) also disables readback for mutations. Kernel write errors are
    // synchronous; unread route broadcasts must never fill a retained socket.
    (void)shutdown(fd, SHUT_RD);
    return fd;
}

int vpn_routes_gateway4(int fd, uint32_t network, uint8_t prefix, uint32_t gateway, int adding) {
    if (prefix > 32 || gateway == 0) return EINVAL;
    struct {
        struct rt_msghdr header;
        struct sockaddr_in destination, gateway, mask;
    } message;
    memset(&message, 0, sizeof(message));
    int seq = __atomic_add_fetch(&route_sequence, 1, __ATOMIC_RELAXED);
    message.header.rtm_msglen = sizeof(message);
    message.header.rtm_version = RTM_VERSION;
    message.header.rtm_type = adding ? RTM_ADD : RTM_DELETE;
    // Match route(8)'s explicit -net form, including /32 netmasks.
    message.header.rtm_flags = RTF_UP | RTF_STATIC | RTF_GATEWAY;
    message.header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    message.header.rtm_seq = seq;
    message.header.rtm_pid = getpid();
    message.destination.sin_len = sizeof(struct sockaddr_in);
    message.destination.sin_family = AF_INET;
    message.destination.sin_addr.s_addr = htonl(network);
    message.gateway.sin_len = sizeof(struct sockaddr_in);
    message.gateway.sin_family = AF_INET;
    message.gateway.sin_addr.s_addr = htonl(gateway);
    message.mask.sin_len = sizeof(struct sockaddr_in);
    message.mask.sin_family = AF_INET;
    message.mask.sin_addr.s_addr = htonl(prefix == 0 ? 0 : UINT32_MAX << (32 - prefix));
    ssize_t sent;
    do { sent = write(fd, &message, sizeof(message)); } while (sent < 0 && errno == EINTR);
    if (sent < 0) return errno;
    if (sent != (ssize_t)sizeof(message)) return EIO;
    // A complete successful write is the kernel mutation receipt, as used by
    // Apple route(8). Exact ownership is still checked before every deletion.
    return 0;
}

int vpn_routes_gateway6(int fd, const uint8_t network[16], uint8_t prefix,
                       const uint8_t gateway[16], uint32_t scope_id, int adding) {
    if (!network || !gateway || prefix > 128) return EINVAL;
    struct {
        struct rt_msghdr header;
        struct sockaddr_in6 destination, gateway, mask;
    } message;
    memset(&message, 0, sizeof(message));
    message.header.rtm_msglen = sizeof(message);
    message.header.rtm_version = RTM_VERSION;
    message.header.rtm_type = adding ? RTM_ADD : RTM_DELETE;
    message.header.rtm_flags = RTF_UP | RTF_STATIC | RTF_GATEWAY;
    message.header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    message.header.rtm_seq = __atomic_add_fetch(&route_sequence, 1, __ATOMIC_RELAXED);
    message.header.rtm_pid = getpid();
    message.destination.sin6_len = message.gateway.sin6_len = message.mask.sin6_len = sizeof(struct sockaddr_in6);
    message.destination.sin6_family = message.gateway.sin6_family = message.mask.sin6_family = AF_INET6;
    memcpy(&message.destination.sin6_addr, network, 16);
    memcpy(&message.gateway.sin6_addr, gateway, 16);
    for (int i = 0; i < 16; i++) {
        int bits = (int)prefix - i * 8;
        uint8_t mask = bits >= 8 ? 255 : bits <= 0 ? 0 : (uint8_t)(255 << (8 - bits));
        if ((network[i] & (uint8_t)~mask) != 0) return EINVAL;
        message.mask.sin6_addr.s6_addr[i] = mask;
    }
    if (IN6_IS_ADDR_UNSPECIFIED(&message.gateway.sin6_addr) || IN6_IS_ADDR_MULTICAST(&message.gateway.sin6_addr)) return EINVAL;
    if (IN6_IS_ADDR_LINKLOCAL(&message.gateway.sin6_addr)) {
        if (scope_id == 0 || scope_id > UINT16_MAX || gateway[2] || gateway[3]) return EINVAL;
        // Darwin route(8) embeds a link-local zone in bytes 2..3 (KAME ABI).
        // The portable input and the journal continue to store the scope as
        // %interface; only the kernel message contains the embedded index.
        message.gateway.sin6_addr.s6_addr[2] = (uint8_t)(scope_id >> 8);
        message.gateway.sin6_addr.s6_addr[3] = (uint8_t)scope_id;
    } else if (scope_id != 0) return EINVAL;
    ssize_t sent;
    do { sent = write(fd, &message, sizeof(message)); } while (sent < 0 && errno == EINTR);
    if (sent < 0) return errno;
    return sent == (ssize_t)sizeof(message) ? 0 : EIO;
}
