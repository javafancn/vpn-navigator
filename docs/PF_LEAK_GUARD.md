# PF leak guard: architecture preview (NOT ACTIVE)

The repository provides a pure, unit-tested `FirewallRulePreview` policy
renderer. It produces a proposed per-physical-interface PF anchor with a
pinned numeric VPN server/port exception, local-network exceptions, China IPv4
exceptions (for China Direct), and physical IPv4+IPv6 blocking rules.

**It is not connected to the privileged helper and does not call pfctl.**
Do not label VPN Navigator as having a working kill switch.

Activation remains blocked until signed-machine tests can prove:
- PF is actually enabled and the app anchor is called from the host's main
  PF ruleset *before* broader quick pass rules; merely running
  `pfctl -a name -f rules` may populate an anchor that is never evaluated.
- Host PF rules are not replaced or flushed, and enabling/disabling PF
  respects any existing reference tokens from other software.
- Established PF states cannot bypass the guard after Wi-Fi changes,
  sleep/wake, changing IPv4 addresses, or an OpenVPN tunnel crash.
- Server re-resolution, DHCP, DNS, local subnet exceptions, and split routing
  cannot cause leaks or lock the Mac out of the Internet.
- An emergency recovery/disable path is tested on a spare Mac.
- IPv6 routing and enterprise VPN coexistence are validated.

The candidate is deliberately **not a deployable PF firewall policy**. The
app continues to reject unsafe unmanaged IPv6 routes in IPv4-only modes.

The macOS runner's `PF preview syntax checks` workflow compiles a
read-only `VPNNavigatorPFPreview` executable and runs `pfctl -vnf`
on a generated sample. A pass proves **parser syntax only**, not routing
or security enforcement.

## Static guard constraints

The syntax-only candidate rejects a 0/0 local exception and invalid or
special-purpose `China Direct` CIDR entries. It must still not be loaded
or offered as a proven kill switch; PF evaluation order, other interfaces,
state handling and signed-machine failover require real packet capture and
host integration testing.
