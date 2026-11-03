#ifndef CVPN_ROUTES_H
#define CVPN_ROUTES_H
#include <stdint.h>
#include <stddef.h>
// Root-only Darwin routing socket. Addresses are in host byte order.
int vpn_routes_open(void);
int vpn_routes_gateway4(int fd, uint32_t network, uint8_t prefix, uint32_t gateway, int adding);
// IPv6 byte arrays are network-order, canonical, unscoped addresses. Link-local
// gateways require an explicit interface index; other gateways require zero.
int vpn_routes_gateway6(int fd, const uint8_t network[16], uint8_t prefix,
                       const uint8_t gateway[16], uint32_t scope_id, int adding);
// Read-only RTM_GET channel, kept separate from the write-only mutation socket.
int vpn_routes_reader_open(void);
int vpn_routes_inspect(int fd, int family, const uint8_t *network, uint8_t prefix,
                      char *output, size_t capacity);
int vpn_routes_lookup(int fd, int family, const uint8_t *address, char *output, size_t capacity);
int vpn_routes_ipv6_defaults(char *output, size_t capacity);
int vpn_routes_ipv6_defaults_decode(const void *data, size_t length, char *output, size_t capacity);
int vpn_routes_local_networks(int family, char *output, size_t capacity);
int vpn_routes_local_networks_decode(const void *data, size_t length, int family, char *output, size_t capacity);
// Shared decoder exposed for captured-message regression tests.
int vpn_routes_decode(const void *message, size_t length, int family,
                      char *output, size_t capacity);
#endif
