# Managed DNS and route application (0.8.9 / Build 29)

Original mode preserves its profile/server DNS behavior. Full VPN and China
Direct prefer the server's global DNS; when it is absent, Cloudflare and Quad9
are selected for the address families actually allocated to the VPN. Corporate
supplemental DNS dictionaries remain intact and their resolver paths are also
pinned to the tunnel. The routing page states the fallback policy.

OpenVPN 2.7 converts traditional DHCP DNS into its DNS hook variables, including
when a server provides both legacy and modern forms. The adapter parses those
variables as data and calls a fixed native helper operation. All dynamic-store
keys come from the protected journal; isolated hook environments do not need
inherited service identifiers. Native dictionaries replace scutil output parsing.
A nonzero DNS up-hook result fails the connection instead of becoming a silent
fallback. Native and installed tests cover both server formats.

Resolver /32 and /128 routes take precedence over country and custom direct
rules. Existing OpenVPN-owned resolver host routes on the verified tunnel may be used
without journaling or deleting them. Their host prefixes are subtracted from the physical allow list as well,
so protection and the actual route plan agree. A DNS resolver conflicting with
the transport endpoint or current LAN is rejected instead of silently breaking
the endpoint's physical path. Live mode changes retain the same resolver pins.
Route explanations identify these resolver exceptions explicitly.

The DNS journal records both known-owned values before publishing a managed
resolver change. Recovery accepts either recorded value and still refuses an
unknown external change. The trusted down-hook leaves DNS
restoration to the journal after child exit, avoiding two restoration owners.

Bulk IPv4 gateway changes now reuse a close-on-exec Darwin routing socket,
following the same synchronous kernel write/error behavior as Apple route(8).
The append-only journal reuses one validated, private, no-follow file descriptor.
Every individual mutation still has a synchronized begin and commit record;
there is no deferred durability or batch of uncommitted system changes.
Existing exact ownership checks remain mandatory before deletion. Interface and
IPv6 mutations retain the system-tool path.

Native acceptance and its precise forwarding/isolation limits are specified in
[MANAGED_CONNECTION_ACCEPTANCE.md](MANAGED_CONNECTION_ACCEPTANCE.md). Connection
timings are reported separately from deliberate watchdog waits and cleanup.
