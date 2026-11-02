# 0.8.13 working-tree performance fixes

The installed application remains a separate build. These changes and local
measurements apply to the current source, compiled with optimization and a debug
entry for isolated component tests. They do not claim a completed three-mode
public-network or installed-app acceptance run.

| Component | Before | After, same local host |
| --- | --- | --- |
| Independent UDP DNS queries | 64 of 80 succeeded; the rest never reached upstream | 1,000 of 1,000 first attempts succeeded in about 0.27 seconds |
| Concurrent DNS | Retained client slots could reject incoming or queued flows | 96 distinct active UDP clients complete, including delayed primaries |
| 4,096 IPv6 prefixes, planning only | About 1.30 seconds in optimized code | About 0.0025 seconds in optimized code |

UDP now uses one nonblocking socket bound to loopback, bounded receive batches,
bounded socket buffers, and the existing 128-query upstream budget. There is no
UDP client-connection cache to exhaust or evict. TCP retains bounded connection
and idle-time handling; new/partial frames and outstanding replies are protected.
No domain caching or query logging was added. Domestic/VPN policy groups and
VPN-only fallback for unlisted names remain enforced.

IPv6 planning sorts canonical networks and removes contained prefixes in one
scan. Tests retain disjoint coverage, nested prefixes, custom VPN exceptions,
and protected DNS host exclusions. IPv6 gateway route mutations use the same
retained native socket strategy as IPv4; each mutation still fsyncs its begin
and commit, and deletion still verifies exact ownership. Interface routes keep
their existing backend. The native message tests capture writes using Unix
socket pairs, cover every prefix length and scope encoding, and reject unsafe
inputs without modifying any OS route. Message semantics were checked against
[Apple's route implementation](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.c).
The installed disposable CI fixture compares native IPv6 gateway routes with
route(8) and must pass before publishing this change.

Session snapshots now include optional monotonic millisecond timings for
preparation, engine startup, negotiation, DNS, route planning/application,
verification, resolver activation and total. Old snapshots remain decodable.
Only fixed stage names and durations are included; no endpoint, domain, raw
engine output, profile or credentials are recorded. Negotiation includes
authentication and the engine's DNS hook; it is not a pure TLS-only timer.

The installed CI harness now measures matched Original/Full/China Direct
DNS and HTTPS paths, cold and warm names, TCP/TLS/first-byte/total durations,
and paired median/P95 latency. A synthetic CA verifies the HTTPS certificate.
The throughput retention gate increases from 50% to 85%, with baseline drift
and uncertainty still failing as inconclusive. See
[acceptance budgets](MANAGED_CONNECTION_ACCEPTANCE.md).

Local checks cover optimized helper/core builds, loopback DNS, native IPv6
message encoding, route ordering/recovery with an injected OS, certificate-
verified loopback HTTPS, timing/gate regressions and localization. This host
still lacks full Xcode, so XCTest, the complete SwiftUI application, actual
three-mode installed networking, and the native kernel mutation fixture have
not been validated here. No hardware acceptance row is marked passed.
