# DNS splitting and intentional disconnect (0.8.12 / Build 32)

## Reported symptoms and causes

A domestic HTTP egress IP does not prove local DNS resolution or local CDN
selection. China Direct previously forced every resolver through the VPN,
including domestic names. It now uses an in-process, session-owned loopback DNS
relay for both UDP and TCP. Complete labels from the pinned domestic-domain
snapshot select AliDNS on explicitly verified physical host routes. Unlisted
names use the server's global VPN DNS (or the existing Cloudflare/Quad9 fallback).
A domestic resolver failure can fall back to VPN DNS; a VPN resolver failure
never falls back to domestic DNS for unlisted names. The relay does not log
queries or cache answers; normal macOS TTL caching remains responsible for cache
expiry. Existing corporate supplemental match-domain resolvers remain intact.

The list contains 109,455 domains from felixonmars/dnsmasq-china-list commit
`a8942d3ac6ebd8dcfc582d4e97fbb443a2176cb2`. Only resolver directives were
removed; no wildcard country TLD is inferred. The payload is size-bounded,
root-protected and checked against a compiled SHA-256 before use. Attribution
and upstream license are included in the app. Updating it requires a reviewed
application build, not a network request during Connect.

Primary domestic endpoints are `223.5.5.5`, `223.6.6.6`, or on an IPv6-only physical path
`2400:3200::1`, `2400:3200:baba::1`. If these overlap a protected server
resolver, select a non-overlapping Tencent DNSPod alternative (`119.29.29.29`,
or `2402:4e00::` / `2402:4e00:1::`). At most two physical resolvers are selected;
if every candidate is protected, domestic queries safely use VPN DNS. See
[DNSPod's endpoint documentation](https://cloud.tencent.com.cn/document/product/302/110786).
A transport endpoint or a VPN resolver can
never become a direct DNS exception. Physical resolver host prefixes take
precedence over overlapping custom VPN ranges, and are included in PF direct
allow lists. Other addresses in those ranges retain their original policy.

The relay binds only `127.0.0.1` at an OS-selected high port, with a maximum of
64 client flows and 128 upstream transactions. Upstreams use numeric addresses,
randomized transaction IDs, connected sockets and matching questions; DNS TCP
framing, persistent streams, A/AAAA and truncated UDP/TCP retry are supported.
It never binds port 53 or creates `/etc/resolver` files. The port is published in
native `ServerAddresses`/`ServerPort` dynamic-store properties only after both
listeners and the kernel routes are ready. Apple's configd DNS implementation
explicitly handles ServerPort in `Plugins/IPMonitor/dns-configuration.c`.

The existing DNS write-ahead journal records original, previous owned and next
owned dictionaries before publication. External edits remain conflicts. Full
VPN restores the saved upstream dictionary and removes the relay/direct DNS
exceptions; live switches keep the TLS session. On Disconnect the child exits,
DNS is restored, the relay stops, and only confirmed owned routes/PF resources
are released. Recovery evidence remains on a real failure.

A second issue concerned status polling: restoring thousands of owned routes
may take longer than the ordinary 12-second poll deadline. Polls queued behind
Disconnect could time out and show a spurious failed session. The app now holds
a disconnect transaction flag, advances the status epoch on both boundaries,
ignores stale snapshots and does not issue status polls while that operation is
pending. It shows “Stopping and restoring” until the operation returns and a new
authenticated snapshot is read. A manual cancellation also prevents a watchdog
route check from turning the intentional stop into a network-change failure.

## Verification and limits

- Core tests cover domain boundary/case/punycode matching, malformed DNS,
  transaction/question identity, physical/VPN DNS conflicts, and route exceptions.
- All four Swift CI runners execute the real production UDP/TCP relay against
  separate local domestic/VPN fixtures, including parallel requests, split TCP
  writes, persistent streams, A/AAAA, TC retry, invalid/refused reply fallback,
  VPN-only failure, and deterministic domestic/remote delay separation.
- Synthetic-service DNS tests cover port publication, live return to global DNS,
  exact restoration and external-edit refusal.
- Installed-system CI verifies actual system DNS through the loopback high port
  followed by encrypted IPv4 HTTP, exact physical resolver host routes,
  Original/Global/China Direct, live switches, watchdog ticks and a real manual
  disconnect/reconnect with 4,096 country routes. Real Quit and upgrade/uninstall
  acceptance remain enabled.

These fixtures establish behavior and eliminate an unnecessary DNS detour; they
do not measure the user's ISP or promise FLCash/Mihomo throughput parity. Browser
DoH, private relay and application-specific resolvers can bypass system DNS;
country allocation rules still determine the final IP data path. Unlisted
domestic names use VPN DNS until added in a reviewed list update.
