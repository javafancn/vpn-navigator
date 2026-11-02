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

// A Unix datagram pair captures the production encoder's exact write. This
// never opens PF_ROUTE, requires no root and cannot alter any system route.
int main(void) {
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
