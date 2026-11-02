#ifndef CVPN_ROUTES_H
#define CVPN_ROUTES_H
#include <stdint.h>
// Root-only Darwin routing socket. Addresses are in host byte order.
int vpn_routes_open(void);
int vpn_routes_gateway4(int fd, uint32_t network, uint8_t prefix, uint32_t gateway, int adding);
// IPv6 byte arrays are network-order, canonical, unscoped addresses. Link-local
// gateways require an explicit interface index; other gateways require zero.
int vpn_routes_gateway6(int fd, const uint8_t network[16], uint8_t prefix,
                       const uint8_t gateway[16], uint32_t scope_id, int adding);
#endif
