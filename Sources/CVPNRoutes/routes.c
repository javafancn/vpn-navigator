#include "CVPNRoutes.h"
#include <sys/socket.h>
#include <net/route.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

int vpn_routes_open(void) {
    int fd = socket(PF_ROUTE, SOCK_RAW, AF_INET);
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
    static int sequence;
    int seq = __atomic_add_fetch(&sequence, 1, __ATOMIC_RELAXED);
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
    if (sent != sizeof(message)) return EIO;
    // A complete successful write is the kernel mutation receipt, as used by
    // Apple route(8). Exact ownership is still checked before every deletion.
    return 0;
}
