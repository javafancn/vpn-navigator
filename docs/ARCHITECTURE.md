# VPN Navigator — current architecture and trust boundaries

## Alpha implementation

**User UI**: SwiftUI application with macOS menu bar, native sidebar, per-profile policies, status and route diagnostics. Can be built without a privileged helper for preview.

**Core**: `VPNNavigatorCore` provides CIDR parse/match/diff, safe OpenVPN profile allowlisting, relative certificate materialization into a private runtime copy, route plan generation, rule update staging, and a local profile repository.

**Privileged helper**: separate CLI executable started by signed SMAppService LaunchDaemon. Receives only typed XPC messages from client apps with the expected Team ID and bundle identifiers. Opens trusted bundled OpenVPN executable only from root-owned non-user-writable /Applications path, verified against signed designated requirement.

**OpenVPN connection**: detached OpenVPN 2.x process, Unix-domain management socket, startup hold, status parsing, username/password transferred from GUI Keychain through authenticated XPC and written to a root-owned ephemeral credential file removed on shutdown. Do not log credentials.

**Routing**: for China Direct, `route-noexec` delegates route responsibility to the helper. Pins the connected remote VPN endpoint to physical gateway first, then country exceptions, then two VPN /1 default routes. Records each installed route and rolls them back on disconnect / errors, with JSON journal recovery on helper restart.

**Rule updates**: user-scoped signed LaunchAgent fetches source data daily, verifies and stages a candidate, asks helper to apply deltas to any active split session, then commits the local snapshot. No downloaded script is executed.

**DNS**: relies on OpenVPN 2.7 client-provided platform DNS integration and server-pushed options, *not* a custom DNS proxy. Correctness for corporate split DNS and restoration remains unverified.

**IPv6**: IPv4-only Full VPN and China Direct modes refuse a detected non-tunnel IPv6 default route. This is a conservative, incomplete safeguard, not full IPv6 support. No Kill Switch claim.

## Security limitations before distribution

1. XPC signing/SMAppService registration must be tested with the actual Developer ID Team; ad-hoc builds intentionally cannot authorize helper.
2. Signed root-owned installation must be verified, including symlink/permission changes and uninstallation.
3. Obtain / package a relocatable reviewed OpenVPN 2.x build with its dependent libraries, and fulfill GPLv2 obligations.
4. Review re-entrant management callbacks and failure handling; catch process termination and DNS leftovers.
5. Confirm safe route ownership under multiple VPNs, Wi-Fi transitions, laptop sleep/wake, overlapping enterprise CIDRs, VPN server address changes, and route table collisions.
6. System default DNS and IPv6 behavior must be measured on dual-stack machines; dynamic DNS correctness isn't assured by unit tests.
7. Strict allowlist intentionally rejects many valid OpenVPN directives. Unsupported scripts, TAP devices, outside-of-folder external files and proprietary plugins are NOT supported.
8. Bundle is not notarized, and no signed production binary is distributed.

## Build
```bash
swift test
zsh scripts/build-app.sh
```
The generated unsigned app is GUI-only without a signed, bundled OpenVPN engine.

Do not claim production readiness based on green CI. Hardware tests in docs/QA.md are release gates.

## New profile maintenance and release features

ProfileStore now preserves validated, self-contained runtime versions alongside
original-source revisions. Editing is disabled while a VPN session is active.
The native SwiftUI editor warns that inline private keys can be visible.

Release metadata is fetched only from the project's GitHub Releases API. A
downloaded installer is accepted only from the same repository release path,
after validation of the parent application's Developer ID Team, a matching
Developer ID Installer certificate, and successful macOS Gatekeeper assessment.
It is then **opened in the macOS Installer**, never executed as root by VPN
Navigator. Updates refuse to run while the privileged helper is enabled.

The package preinstall script also refuses to upgrade while active VPN processes
or unresolved route journals remain. Signed release builds require a reviewed
OpenVPN 2.7.x engine, matching GPL source archive and third-party notices.

## Additional boundaries: October 2026

- Incoming and outgoing XPC peers are checked by macOS connection-level
  designated code-signing requirements (macOS 13+), not only process PID.
- Country route feeds are bounded to 2 MB / 30,000 unique entries. Special
  ranges are excluded by CIDR *overlap* including broader aggregates.
- Live route updates compare filtered route-plan targets after protecting
  on-link LAN prefixes and pinning the VPN server endpoint.
- RuleUpdater maintains at most ten validated snapshots and supports guarded
  UI-driven rollback (also subject to the candidate change policy).
- If a helper restarts and finds a possible orphaned OpenVPN session, it
  refuses another connection instead of assuming the old process is dead.
  Recovery of the root process requires real process identity verification
  and is deliberately not automated.
- Read-only diagnostics expose route interface/IPv6 category/resolver counts;
  private DNS domains are not displayed in the GUI.

**Not implemented:** reliably terminating orphaned OpenVPN processes after
a daemon crash; a stateful PF-based kill switch and full IPv6 geo-splitting;
VPN/DNS packet-level leak certification; seamless, no-impact route update
under every gateway and pushed corporate route configuration.
