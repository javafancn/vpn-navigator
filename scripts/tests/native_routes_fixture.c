#include "CVPNRoutes.h"
#include <sys/socket.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <net/if.h>
#include <sys/wait.h>
#include <stdlib.h>

static void ipv6_defaults_tests(void) {
    struct { struct rt_msghdr h; struct sockaddr_in6 dst, gateway, mask; } frames[2];
    memset(frames, 0, sizeof(frames));
    for (int i = 0; i < 2; i++) {
        frames[i].h.rtm_msglen = sizeof(frames[i]); frames[i].h.rtm_version = RTM_VERSION;
        frames[i].h.rtm_type = RTM_GET; frames[i].h.rtm_index = if_nametoindex("lo0");
        frames[i].h.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
        frames[i].h.rtm_flags = RTF_UP | RTF_IFSCOPE | RTF_GATEWAY;
        struct sockaddr_in6 *addresses[] = { &frames[i].dst, &frames[i].gateway, &frames[i].mask };
        for (int j = 0; j < 3; j++) { addresses[j]->sin6_len = sizeof(struct sockaddr_in6); addresses[j]->sin6_family = AF_INET6; }
        assert(inet_pton(AF_INET6, "fe80::1", &frames[i].gateway.sin6_addr) == 1);
        frames[i].gateway.sin6_scope_id = frames[i].h.rtm_index;
    }
    frames[1].mask.sin6_addr.s6_addr[0] = 128; // ::/1 is not a default.
    char output[2048];
    assert(vpn_routes_ipv6_defaults_decode(frames, sizeof(frames), output, sizeof(output)) == 0);
    assert(strstr(output, "default fe80::1%lo0 UI lo0\n"));
    const char *only = strstr(output, "default"); assert(only && !strstr(only + 7, "default"));
    assert(vpn_routes_ipv6_defaults_decode(frames, sizeof(frames) - 1, output, sizeof(output)) == EINVAL);
    assert(vpn_routes_ipv6_defaults_decode(NULL, 0, output, sizeof(output)) == 0 && !strstr(output, "default"));
    frames[0].h.rtm_addrs &= ~RTA_NETMASK;
    assert(vpn_routes_ipv6_defaults_decode(frames, sizeof(frames[0]), output, sizeof(output)) == EINVAL);
    puts("PASS: native IPv6 default snapshot preserves scoped gateways, ignores split defaults, and rejects malformed or unmasked entries.");
}

static void reader_tests(void) {
    struct { struct rt_msghdr h; struct sockaddr_in dst, gateway, mask; } message;
    memset(&message, 0, sizeof(message));
    message.h.rtm_msglen = sizeof(message); message.h.rtm_version = RTM_VERSION;
    message.h.rtm_type = RTM_GET; message.h.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    message.h.rtm_flags = RTF_GATEWAY;
    message.h.rtm_index = if_nametoindex("lo0"); assert(message.h.rtm_index);
    struct sockaddr_in *addresses[] = { &message.dst, &message.gateway, &message.mask };
    const char *texts[] = { "223.5.5.0", "192.0.2.1", "255.255.255.0" };
    for (int i = 0; i < 3; i++) {
        addresses[i]->sin_len = sizeof(struct sockaddr_in); addresses[i]->sin_family = AF_INET;
        assert(inet_pton(AF_INET, texts[i], &addresses[i]->sin_addr) == 1);
    }
    char output[1024];
    assert(vpn_routes_decode(&message, sizeof(message), AF_INET, output, sizeof(output)) == 0);
    assert(strstr(output, "destination: 223.5.5.0\n") && strstr(output, "gateway: 192.0.2.1\n"));
    assert(strstr(output, "mask: 255.255.255.0\n") && strstr(output, "interface: lo0\n"));
    assert(vpn_routes_decode(&message, sizeof(message) - 1, AF_INET, output, sizeof(output)) == EINVAL);
    assert(vpn_routes_decode(&message, sizeof(message), AF_INET, output, 4) == EMSGSIZE);
    message.mask.sin_len = 0; message.mask.sin_family = 0;
    assert(vpn_routes_decode(&message, sizeof(message), AF_INET, output, sizeof(output)) == 0);
    assert(strstr(output, "mask: 0.0.0.0\n"));
    message.mask.sin_len = sizeof(struct sockaddr_in);
    message.h.rtm_errno = ESRCH;
    assert(vpn_routes_decode(&message, sizeof(message), AF_INET, output, sizeof(output)) == 0 && !output[0]);
    message.h.rtm_errno = EACCES;
    assert(vpn_routes_decode(&message, sizeof(message), AF_INET, output, sizeof(output)) == EACCES);
    message.h.rtm_errno = 0;
    struct { struct rt_msghdr h; struct sockaddr_in6 dst, gateway, mask; } v6;
    memset(&v6, 0, sizeof(v6));
    v6.h = message.h; v6.h.rtm_msglen = sizeof(v6);
    struct sockaddr_in6 *v6addresses[] = { &v6.dst, &v6.gateway, &v6.mask };
    const char *v6texts[] = { "2001:db8:abcd::", "fe80::1", "ffff:ffff:ffff::" };
    for (int i = 0; i < 3; i++) {
        v6addresses[i]->sin6_len = sizeof(struct sockaddr_in6); v6addresses[i]->sin6_family = AF_INET6;
        assert(inet_pton(AF_INET6, v6texts[i], &v6addresses[i]->sin6_addr) == 1);
    }
    v6.gateway.sin6_addr.s6_addr[2] = (uint8_t)(v6.h.rtm_index >> 8);
    v6.gateway.sin6_addr.s6_addr[3] = (uint8_t)v6.h.rtm_index;
    assert(vpn_routes_decode(&v6, sizeof(v6), AF_INET6, output, sizeof(output)) == 0);
    assert(strstr(output, "gateway: fe80::1%lo0\n") && strstr(output, "mask: ffff:ffff:ffff::\n"));
    v6.mask.sin6_len = offsetof(struct sockaddr_in6, sin6_addr) + 6; v6.mask.sin6_family = 0;
    v6.h.rtm_msglen = sizeof(v6.h) + 2 * sizeof(struct sockaddr_in6) + 16;
    assert(vpn_routes_decode(&v6, v6.h.rtm_msglen, AF_INET6, output, sizeof(output)) == 0);
    assert(strstr(output, "mask: ffff:ffff:ffff::\n"));
    v6.gateway.sin6_scope_id = v6.h.rtm_index + 1;
    assert(vpn_routes_decode(&v6, v6.h.rtm_msglen, AF_INET6, output, sizeof(output)) == EINVAL);
    // HOST replies may omit netmask; never infer a host from a network reply.
    message.h.rtm_addrs = RTA_DST | RTA_GATEWAY; message.h.rtm_flags = RTF_HOST | RTF_GATEWAY;
    assert(vpn_routes_decode(&message, sizeof(message), AF_INET, output, sizeof(output)) == 0);
    assert(strstr(output, "mask: 255.255.255.255\n"));
    message.h.rtm_flags = RTF_GATEWAY;
    assert(vpn_routes_decode(&message, sizeof(message), AF_INET, output, sizeof(output)) == 0);
    assert(!strstr(output, "mask:"));
    message.h.rtm_addrs |= RTA_NETMASK;
    for (int fail = 0; fail < 3; fail++) {
        int sockets[2]; assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) == 0);
        pid_t child = fork(); assert(child >= 0);
        if (child == 0) {
            close(sockets[0]);
            uint8_t query[1024]; ssize_t count = read(sockets[1], query, sizeof(query));
            assert(count >= (ssize_t)sizeof(struct rt_msghdr));
            struct rt_msghdr header; memcpy(&header, query, sizeof(header));
            assert(header.rtm_type == RTM_GET);
            assert(!!(header.rtm_addrs & RTA_NETMASK) == (fail != 2));
            if (fail == 2) assert(header.rtm_flags & RTF_HOST);
            message.h.rtm_pid = header.rtm_pid; message.h.rtm_seq = header.rtm_seq - 1;
            assert(write(sockets[1], &message, sizeof(message)) == sizeof(message));
            message.h.rtm_seq = header.rtm_seq; message.h.rtm_errno = fail == 1 ? EACCES : 0;
            assert(write(sockets[1], &message, sizeof(message)) == sizeof(message));
            close(sockets[1]); _exit(0);
        }
        close(sockets[1]); uint8_t network[] = {223, 5, 5, 0};
        int result = fail == 2 ? vpn_routes_lookup(sockets[0], AF_INET, network, output, sizeof(output)) : vpn_routes_inspect(sockets[0], AF_INET, network, 24, output, sizeof(output));
        assert(result == (fail == 1 ? EACCES : 0));
        if (fail != 1) assert(strstr(output, "gateway: 192.0.2.1\n"));
        close(sockets[0]); int status; assert(waitpid(child, &status, 0) == child && status == 0);
    }
    puts("PASS: read-only ownership decoding, malformed/truncated messages, absent routes, errors and reply sequence filtering.");
}

// A Unix datagram pair captures the production encoder's exact write. This
// never opens PF_ROUTE, requires no root and cannot alter any system route.
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--defaults6") == 0) {
        char output[32768]; int result = vpn_routes_ipv6_defaults(output, sizeof(output));
        if (result) { fprintf(stderr, "IPv6 snapshot error: %d\n", result); return 1; }
        puts(output); return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--lookup4") == 0) {
        uint8_t address[4]; assert(inet_pton(AF_INET, argv[2], address) == 1);
        int fd = vpn_routes_reader_open(); assert(fd >= 0);
        char output[1024]; int result = vpn_routes_lookup(fd, AF_INET, address, output, sizeof(output)); close(fd);
        if (result) { fprintf(stderr, "Lookup error: %d\n", result); return 1; }
        puts(output); return 0;
    }
    if (argc == 4 && strcmp(argv[1], "--inspect4") == 0) {
        uint8_t network[4]; assert(inet_pton(AF_INET, argv[2], network) == 1);
        int fd = vpn_routes_reader_open(); assert(fd >= 0);
        char output[1024]; int result = vpn_routes_inspect(fd, AF_INET, network, (uint8_t)atoi(argv[3]), output, sizeof(output));
        close(fd);
        if (result) { fprintf(stderr, "RTM_GET error: %d\n", result); return 1; }
        puts(output); return 0;
    }
    reader_tests();
    ipv6_defaults_tests();
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) == 0);
    uint8_t network[16], gateway[16], buffer[1024];
    assert(inet_pton(AF_INET6, "2001:db8:abcd::", network) == 1);
    assert(inet_pton(AF_INET6, "fe80::1", gateway) == 1);
    int sequence = 0;
    for (int prefix = 3; prefix <= 128; prefix++) {
        uint8_t canonical[16];
        for (int i = 0; i < 16; i++) {
            int bits = prefix - i * 8;
            uint8_t mask = bits >= 8 ? 255 : bits <= 0 ? 0 : (uint8_t)(255 << (8 - bits));
            canonical[i] = network[i] & mask;
        }
        for (int adding = 0; adding <= 1; adding++) {
            assert(vpn_routes_gateway6(pair[0], canonical, (uint8_t)prefix, gateway, 513, adding) == 0);
            ssize_t count = recv(pair[1], buffer, sizeof(buffer), 0);
            assert(count == (ssize_t)(sizeof(struct rt_msghdr) + 3 * sizeof(struct sockaddr_in6)));
            struct rt_msghdr header; memcpy(&header, buffer, sizeof(header));
            assert(header.rtm_msglen == count && header.rtm_version == RTM_VERSION);
            assert(header.rtm_type == (adding ? RTM_ADD : RTM_DELETE));
            assert(header.rtm_flags == (RTF_UP | RTF_STATIC | RTF_GATEWAY));
            assert(header.rtm_addrs == (RTA_DST | RTA_GATEWAY | RTA_NETMASK));
            assert(header.rtm_seq > sequence); sequence = header.rtm_seq;
            struct sockaddr_in6 addresses[3]; memcpy(addresses, buffer + sizeof(header), sizeof(addresses));
            for (int i = 0; i < 3; i++) {
                assert(addresses[i].sin6_family == AF_INET6 && addresses[i].sin6_len == sizeof(struct sockaddr_in6));
            }
            assert(memcmp(&addresses[0].sin6_addr, canonical, 16) == 0);
            assert(addresses[1].sin6_addr.s6_addr[2] == 2 && addresses[1].sin6_addr.s6_addr[3] == 1);
            assert(addresses[1].sin6_scope_id == 0 && addresses[1].sin6_addr.s6_addr[15] == 1);
            for (int bit = 0; bit < 128; bit++) {
                assert(!!(addresses[2].sin6_addr.s6_addr[bit / 8] & (128 >> (bit % 8))) == (bit < prefix));
            }
        }
    }
    assert(vpn_routes_gateway6(pair[0], network, 48, gateway, 0, 1) == EINVAL);
    assert(vpn_routes_gateway6(pair[0], network, 48, gateway, 65536, 1) == EINVAL);
    assert(vpn_routes_gateway6(pair[0], network, 129, gateway, 1, 1) == EINVAL);
    network[15] = 1;
    assert(vpn_routes_gateway6(pair[0], network, 48, gateway, 1, 1) == EINVAL);
    network[15] = 0;
    assert(inet_pton(AF_INET6, "2001:4860::1", gateway) == 1);
    assert(vpn_routes_gateway6(pair[0], network, 48, gateway, 1, 1) == EINVAL);
    assert(vpn_routes_gateway6(pair[0], network, 48, gateway, 0, 1) == 0);
    assert(recv(pair[1], buffer, sizeof(buffer), 0) > 0);
    memset(gateway, 0, sizeof(gateway));
    assert(vpn_routes_gateway6(pair[0], network, 48, gateway, 0, 1) == EINVAL);
    assert(recv(pair[1], buffer, sizeof(buffer), MSG_DONTWAIT) == -1 && errno == EAGAIN);
    close(pair[0]); close(pair[1]);
    puts("PASS: native IPv6 add/delete messages, all prefix lengths, masks, scoped/global gateways and invalid-input rejection; no system routes changed.");
    return 0;
}
