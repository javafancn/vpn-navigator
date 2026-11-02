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

#include <arpa/inet.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <poll.h>
#include <stdio.h>
#include <time.h>

int vpn_routes_reader_open(void) {
    int fd = socket(PF_ROUTE, SOCK_RAW, 0);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}

int vpn_routes_decode(const void *message, size_t length, int family, char *output, size_t capacity) {
    if (!output || capacity == 0 || length < sizeof(struct rt_msghdr)) return EINVAL;
    output[0] = 0;
    struct rt_msghdr header;
    memcpy(&header, message, sizeof(header));
    if (header.rtm_version != RTM_VERSION || header.rtm_type != RTM_GET ||
        header.rtm_msglen < sizeof(header) || header.rtm_msglen > length) return EINVAL;
    if (header.rtm_errno == ESRCH) return 0; // absent: never claim ownership
    if (header.rtm_errno) return header.rtm_errno;
    const uint8_t *cursor = (const uint8_t *)message + sizeof(header);
    const uint8_t *end = (const uint8_t *)message + header.rtm_msglen;
    uint8_t destination[16] = {0}, gateway[16] = {0}, mask[16] = {0};
    int address_size = family == AF_INET ? 4 : family == AF_INET6 ? 16 : 0;
    if (!address_size) return EAFNOSUPPORT;
    size_t offset = family == AF_INET ? offsetof(struct sockaddr_in, sin_addr) : offsetof(struct sockaddr_in6, sin6_addr);
    int have_destination = 0, have_gateway = 0, have_mask = !!(header.rtm_flags & RTF_HOST);
    unsigned scope = 0, index = header.rtm_index;
    if (have_mask) memset(mask, 255, (size_t)address_size);
    for (int slot = 0; slot < RTAX_MAX; slot++) {
        if (!(header.rtm_addrs & (1 << slot))) continue;
        if (end - cursor < 2) return EINVAL;
        size_t size = cursor[0];
        // Darwin routing messages align sockaddrs to 32 bits, including zero masks.
        size_t stride = size ? (size + 3) & ~(size_t)3 : 4;
        if (stride > (size_t)(end - cursor)) return EINVAL;
        if (slot == RTAX_NETMASK) {
            memset(mask, 0, sizeof(mask));
            if (size > offset) memcpy(mask, cursor + offset, size - offset < (size_t)address_size ? size - offset : (size_t)address_size);
            have_mask = 1;
        } else if ((slot == RTAX_DST || slot == RTAX_GATEWAY) && cursor[1] == family) {
            if (size < offset + (size_t)address_size) return EINVAL;
            uint8_t *address = slot == RTAX_DST ? destination : gateway;
            memcpy(address, cursor + offset, (size_t)address_size);
            if (slot == RTAX_DST) have_destination = 1;
            else {
                have_gateway = 1;
                if (family == AF_INET6) {
                    if (size < sizeof(struct sockaddr_in6)) return EINVAL;
                    struct sockaddr_in6 value; memcpy(&value, cursor, sizeof(value));
                    scope = value.sin6_scope_id;
                    if (gateway[0] == 0xfe && (gateway[1] & 0xc0) == 0x80) {
                        unsigned embedded = (unsigned)gateway[2] << 8 | gateway[3];
                        if (embedded && scope && embedded != scope) return EINVAL;
                        if (embedded) scope = embedded;
                        gateway[2] = gateway[3] = 0;
                    }
                }
            }
        } else if (slot == RTAX_IFP && cursor[1] == AF_LINK) {
            if (size < offsetof(struct sockaddr_dl, sdl_type)) return EINVAL;
            uint16_t value; memcpy(&value, cursor + offsetof(struct sockaddr_dl, sdl_index), sizeof(value));
            if (index && value && index != value) return EINVAL;
            if (value) index = value;
        }
        cursor += stride;
    }
    if (!have_destination) return EINVAL;
    char dest_text[INET6_ADDRSTRLEN], gateway_text[INET6_ADDRSTRLEN] = "", mask_text[INET6_ADDRSTRLEN] = "", interface[IF_NAMESIZE] = "";
    if (!inet_ntop(family, destination, dest_text, sizeof(dest_text))) return errno;
    if (have_gateway && !inet_ntop(family, gateway, gateway_text, sizeof(gateway_text))) return errno;
    if (have_mask && !inet_ntop(family, mask, mask_text, sizeof(mask_text))) return errno;
    if (index && !if_indextoname(index, interface)) return ENXIO;
    char scope_text[IF_NAMESIZE + 2] = "";
    if (scope) {
        if (scope != index || !interface[0]) return EINVAL;
        snprintf(scope_text, sizeof(scope_text), "%%%s", interface);
    }
    int written = snprintf(output, capacity, "destination: %s\ngateway: %s%s\ninterface: %s\n%s%s\n",
                           dest_text, gateway_text, scope_text, interface, have_mask ? "mask: " : "", mask_text);
    return written < 0 || (size_t)written >= capacity ? EMSGSIZE : 0;
}

static int64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

int vpn_routes_inspect(int fd, int family, const uint8_t *network, uint8_t prefix, char *output, size_t capacity) {
    if (!network || !output || !capacity || (family != AF_INET && family != AF_INET6) || prefix > (family == AF_INET ? 32 : 128)) return EINVAL;
    struct { struct rt_msghdr header; uint8_t addresses[2 * sizeof(struct sockaddr_in6) + sizeof(struct sockaddr_dl)]; } request;
    memset(&request, 0, sizeof(request));
    struct rt_msghdr *h = &request.header;
    h->rtm_version = RTM_VERSION; h->rtm_type = RTM_GET;
    h->rtm_addrs = RTA_DST | RTA_NETMASK | RTA_IFP;
    h->rtm_pid = getpid(); h->rtm_seq = __atomic_add_fetch(&route_sequence, 1, __ATOMIC_RELAXED);
    uint8_t *next = request.addresses;
    size_t size = family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
    size_t offset = family == AF_INET ? offsetof(struct sockaddr_in, sin_addr) : offsetof(struct sockaddr_in6, sin6_addr);
    int bytes = family == AF_INET ? 4 : 16;
    next[0] = (uint8_t)size; next[1] = (uint8_t)family; memcpy(next + offset, network, (size_t)bytes); next += size;
    next[0] = (uint8_t)size; next[1] = (uint8_t)family;
    for (int i = 0; i < bytes; i++) { int bits = prefix - i * 8; next[offset + i] = bits >= 8 ? 255 : bits <= 0 ? 0 : (uint8_t)(255 << (8 - bits)); }
    next += size;
    next[0] = sizeof(struct sockaddr_dl); next[1] = AF_LINK; next += sizeof(struct sockaddr_dl);
    h->rtm_msglen = (uint16_t)(next - (uint8_t *)&request);
    ssize_t sent;
    do { sent = write(fd, &request, h->rtm_msglen); } while (sent < 0 && errno == EINTR);
    if (sent < 0) { if (errno == ESRCH) { output[0] = 0; return 0; } return errno; }
    if (sent != h->rtm_msglen) return EIO;
    int64_t started = monotonic_ms();
    if (started < 0) return EIO;
    for (;;) {
        int64_t now = monotonic_ms();
        if (now < 0) return EIO;
        int remaining = (int)(1000 - (now - started));
        if (remaining <= 0) return ETIMEDOUT;
        struct pollfd item = { .fd = fd, .events = POLLIN };
        int ready = poll(&item, 1, remaining);
        if (ready < 0) { if (errno == EINTR) continue; return errno; }
        if (!ready) return ETIMEDOUT;
        if (item.revents & (POLLERR | POLLHUP | POLLNVAL)) return EIO;
        uint8_t reply[65536];
        ssize_t count = read(fd, reply, sizeof(reply));
        if (count < 0) { if (errno == EINTR || errno == EAGAIN) continue; return errno; }
        if (count < (ssize_t)sizeof(struct rt_msghdr)) return EIO;
        struct rt_msghdr response; memcpy(&response, reply, sizeof(response));
        if (response.rtm_pid != h->rtm_pid || response.rtm_seq != h->rtm_seq || response.rtm_type != RTM_GET) continue;
        return vpn_routes_decode(reply, (size_t)count, family, output, capacity);
    }
}
