# Experimental PF runtime guard

0.2.0 adds an explicit, default-off runtime guard for Full VPN and China Direct. The older FirewallRulePreview remains a read-only tool; LeakGuardPolicy and PacketFilterGuard implement the runtime path.

## Activation and scope

- Require a signed root helper and compatible stock Apple root filter-anchor layout; permit the standard scrub anchor, reject unknown root rules, earlier child anchors and skipped interfaces.
- Resolve/pin one numeric IPv4 VPN endpoint before activating; select its physical interface and verified local exceptions.
- Load only `com.apple/000.vpn-navigator`. Never replace `/etc/pf.conf`, reload host root rules, flush other anchors, or use `pfctl -d`.
- Save an enable receipt and the application's `pfctl -E` token in the root-private runtime directory.
- Reset existing PF states during protection activation, reconstruction, direct-policy tightening and release. This explicitly affects all current connections, including other VPNs.
- Bind new allowed states to their interface with `keep state (if-bound)` so an owned tunnel's state cannot float onto a physical interface after tunnel disappearance.
- Allow the owned tunnel's IPv4, the pinned endpoint, DHCP and selected direct destinations; block all other outward IPv4 and IPv6. Do not advertise IPv6 country routing.

## Failures and recovery

Unexpected failure retains the guard. Retried managed sessions require verified PF ownership, old child exit and unambiguous DNS/route rollback. They retain PF between attempts and have a bounded retry budget.

Explicit disconnect/recovery removes only the owned rules and releases only the recorded enable reference. The enable child's private receipt permits token recovery after a helper crash. Unknown ownership is not authorization to disable PF globally. A live or reused historical OpenVPN PID is never killed by number.

On an incompatible host, the connection fails with an actionable error. The application does not attempt to make arbitrary third-party firewall configurations compatible.

## Automated checks versus release acceptance

Core tests validate policy bounds, endpoint pinning, host-layout rejection and token syntax. The PF syntax workflow parses both preview and strict runtime policies. A disposable CI fixture tests a real kernel anchor against one loopback TCP port and verifies reachability after releasing the application's token. The fixture does not load the production global egress block or reset unrelated external CI connections.

These checks do not certify physical-interface packet behavior. Before removing the experimental label, use signed installers on spare Intel/Apple Silicon Macs and capture IPv4/IPv6 traffic during tunnel failure, old established connections, rule tightening, Wi-Fi/Ethernet changes, sleep/wake, helper crash, server re-resolution and emergency recovery. Record failures as blockers in QA.md.
