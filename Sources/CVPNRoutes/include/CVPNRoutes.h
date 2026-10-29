#ifndef CVPN_ROUTES_H
#define CVPN_ROUTES_H
#include <stdint.h>
// Root-only Darwin routing socket. Addresses are in host byte order.
int vpn_routes_open(void);
int vpn_routes_gateway4(int fd, uint32_t network, uint8_t prefix, uint32_t gateway, int adding);
#endif
