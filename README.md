# VPN Navigator

A native SwiftUI macOS OpenVPN CLI client project with a per-profile route policy engine.

## Development status (alpha; not yet production ready)

- Native macOS SwiftUI app, menu bar, profiles and diagnostics
- Native profile store with configuration groups, favorites, full-text search, secure .ovpn editor, recoverable revisions, preserved original import and relative certificate materialization
- Original / Full VPN / Mainland China IPv4 Direct policies
- Country IPv4 rules with validated updates, CIDR diff and persistence
- Swift helper code for OpenVPN process, Unix management socket, pinned endpoint, route transaction/rollback
- XPC boundary requiring signed Team/allowed app identity
- launchd LaunchAgent for daily IPv4 rule refresh
- Standalone app packaging, signing, notarization and PKG packaging scripts with GPL source/notice checks
- Verified GitHub Release PKG download (same Developer ID Team + Gatekeeper) with explicit system Installer handoff
- Swift macOS CI unit tests and unsigned developer UI-only app build

**Not yet proven or delivered as a production VPN client:** audited signed/distributed OpenVPN binaries and dependency notices, notarized distribution, real root Helper registration, live VPN + DNS/IPv6 integration tests, traffic leak testing, complete split-route reliability, true firewall kill switch, full historical .ovpn support or unattended kernel upgrades.

## Build (macOS 13+, Xcode Swift toolchain)

```sh
swift test
swift run VPNNavigatorApp
zsh scripts/build-app.sh
```

`dist/VPN Navigator.app` without a Developer ID signature and vetted bundled OpenVPN CLI is **UI-only**, and refuses privileged operation. It is NOT a working production VPN.

## Signed distribution

See [INSTALL_AND_RELEASE.md](docs/INSTALL_AND_RELEASE.md). Sign with Developer ID, bundle a vetted relocatable GPL-compliant OpenVPN 2.x binary, use `scripts/build-app.sh`, then `scripts/build-pkg.sh` and notarize. Helper only executes binaries from root-owned signed app under /Applications; it cannot execute arbitrary paths. Sign-off requires physical macOS route/DNS/IPv6 testing.

## Security

No arbitrary scripts or plugins in imported OpenVPN profile are run as root. Only allowlisted directives and relative certificate files are allowed; unsupported profiles fail closed with a clear error. All imported originals are preserved separately and stored privately. Never commit secrets, .ovpn, .key, .p12 or .pfx files.

For architectural and safety caveats, read [ARCHITECTURE.md](docs/ARCHITECTURE.md).

Rule feed: [chnroutes2](https://github.com/misakaio/chnroutes2), which requires license/attribution review for redistributions. OpenVPN Community 2.x has separate GPL obligations.

## October 2026 safety and maintenance hardening

- IPv4 country feeds now reject CIDRs that overlap RFC-reserved, multicast,
  CGNAT and local-use ranges. Inputs from HTTP and XPC have byte/count limits.
- Live rule updates rebuild the *effective* route plan with on-link LAN
  exclusions instead of blindly applying changes in the source feed.
- Before every country rules commit, a validated previous version is archived
  under private Application Support; recent snapshots can be restored from UI.
- Root XPC now uses macOS 13 `setCodeSigningRequirement` rather than
  validating a peer by PID. Clients also validate the root helper's signing
  identity before sending authentication credentials.
- A previous root-helper crash with a leftover active OpenVPN configuration
  refuses to start another session until the orphan is investigated.
- The diagnostics view can show IPv6 default-route risk and DNS resolver counts
  without revealing private domain names.

These additions require real signed-macOS device testing. They are NOT
equivalent to an audited kill switch, traffic leak guarantees or a production
VPN release. See [QA](docs/QA.md).

## macOS Alpha hardening — October 15, 2026

- VPN disconnect now waits for OpenVPN to exit before restoring custom routes.
  If the child remains alive after graceful termination and forced stop,
  the helper retains the active-profile marker and route journal.
- Native profile switching uses the root helper's actual active profile ID,
  requires explicit confirmation and verifies disconnect before reconnecting.
- Added a bounded, reserved-range-aware IPv6 CIDR parser and offline rule set
  as an **unwired foundation** for eventual dual-stack routing.
  The current China route feed does not supply a corresponding IPv6 text feed.
- Added a pure `FirewallRulePreview` generator and a separate macOS
  `pfctl -vnf` syntax smoke test, without enabling PF or touching the
  system's anchors. This is NOT yet a functioning kill switch.
- Early startup signature failures avoid leaving a false active VPN marker.
  Background helper deregistration checks the daemon's true session state.

The shipping VPN remains **IPv4-only for non-original policies**, refuses
unsafe IPv6 defaults and has no validated PF-enforced leak protection.

## Route-management safety and recovery notes (October 2026)

The managed Full VPN and China Direct modes now reject local `.ovpn`
`route`/`route-ipv6`/`redirect-gateway` statements, and send
OpenVPN compatibility `pull-filter` directives for server-pushed routes.
The original profile remains available for Original mode. **These filters
are not a hostile-server security boundary:** OpenVPN upstream warns that
prefix matching may be bypassed by whitespace variations.

On an OpenVPN RECONNECTING event, route-managed sessions terminate instead
of releasing route ownership while the OpenVPN child is still alive. The
Original mode continues to use OpenVPN's internal reconnect. Automatic safe
reconnect for managed routes requires a verified firewall kill switch and
hardware network-state testing; it is deliberately disabled for now.

The helper writes a private root-owned `openvpn-child.json` containing the
launched child PID. After an abnormal helper exit, **manual safe recovery**
may clear the old session marker if `kill(pid, 0)` conclusively reports
`ESRCH`. Any live/reused PID, missing record or ambiguous route journal
blocks cleanup. No orphan is forcibly killed by PID.
