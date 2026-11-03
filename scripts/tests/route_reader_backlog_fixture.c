// Only routes.c's write() is replaced. Simulate the kernel's synchronous
// reply delivery before write() returns, without touching any system routes.
#ifdef write
#undef write
#endif
#include "CVPNRoutes.h"
#include <sys/socket.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int reader = -1, peer = -1;
static struct { struct rt_msghdr h; struct sockaddr_in dst, gateway, mask; } response;

ssize_t vpn_test_write(int fd, const void *data, size_t count) {
    if (fd != reader) return write(fd, data, count);
    assert(count >= sizeof(struct rt_msghdr));
    const struct rt_msghdr *request = data;
    assert(request->rtm_type == RTM_GET);
    response.h.rtm_type = RTM_GET;
    response.h.rtm_seq = request->rtm_seq; response.h.rtm_pid = request->rtm_pid;
    ssize_t delivered = send(peer, &response, sizeof(response), MSG_DONTWAIT);
    assert(delivered == sizeof(response) || (delivered == -1 && (errno == EAGAIN || errno == ENOBUFS)));
    // A successful query write does not promise that raw_input could enqueue
    // the reply on a full routing socket. There is no retry of that reply.
    return (ssize_t)count;
}

int main(void) {
    memset(&response, 0, sizeof(response));
    response.h.rtm_msglen = sizeof(response); response.h.rtm_version = RTM_VERSION;
    response.h.rtm_flags = RTF_GATEWAY;
    response.h.rtm_index = if_nametoindex("lo0"); assert(response.h.rtm_index);
    response.h.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    struct sockaddr_in *addresses[] = { &response.dst, &response.gateway, &response.mask };
    const char *texts[] = { "223.5.5.0", "192.0.2.1", "255.255.255.0" };
    for (int i = 0; i < 3; i++) {
        addresses[i]->sin_len = sizeof(struct sockaddr_in); addresses[i]->sin_family = AF_INET;
        assert(inet_pton(AF_INET, texts[i], &addresses[i]->sin_addr) == 1);
    }
    for (int round = 0; round < 5; round++) {
        int sockets[2]; assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) == 0);
        reader = sockets[0]; peer = sockets[1];
        int capacity = 4096;
        assert(setsockopt(reader, SOL_SOCKET, SO_RCVBUF, &capacity, sizeof(capacity)) == 0);
        response.h.rtm_type = RTM_ADD;
        size_t queued = 0;
        while (send(peer, &response, sizeof(response), MSG_DONTWAIT) == sizeof(response)) queued++;
        assert(queued > 0 && (errno == EAGAIN || errno == ENOBUFS));
        uint8_t network[] = {223, 5, 5, 0}; char output[1024];
        int result = vpn_routes_inspect(reader, AF_INET, network, 24, output, sizeof(output));
        close(reader); close(peer); reader = peer = -1;
        if (result) { fprintf(stderr, "Full notification queue loses next query reply: errno %d\n", result); return 1; }
        assert(strstr(output, "gateway: 192.0.2.1\n") && strstr(output, "mask: 255.255.255.0\n"));
    }
    puts("PASS: five full notification queues drained before synchronous query reply delivery; no system routes changed.");
}
