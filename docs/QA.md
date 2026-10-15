# VPN Navigator — macOS release acceptance tests

The following checks must be executed on a disposable Mac after Developer ID signing and installation with the PKG, using a testing-only OpenVPN server and disposable credentials.

| ID | Test | Expected |
|---|---|---|
| A01 | Install root-owned signed .app through PKG | Correct root ownership, no group/world write, notarization passes |
| A02 | SMAppService register LaunchDaemon/LaunchAgent | Visible macOS approval, XPC helper reachable |
| A03 | Connect unsigned/mismatched XPC client | Helper rejects the connection |
| A04 | Import profile with embedded certificates | Connect, disconnect, re-connect normally |
| A05 | Import relative ca/cert/key files | Original preserved; runtime copy self-contained |
| A06 | Unsafe script/plugin/management directive | Explicit error, nothing runs as root |
| A07 | Username/password profile | Keychain optional, root temporary auth file removed |
| A08 | Full VPN IPv4 route | Test remote egress and DNS actually use VPN |
| A09 | China Direct, source with thousands of prefixes | CN IP uses physical network; foreign IPv4 uses utun |
| A10 | VPN server located within China CIDR | Endpoint /32 pin remains physical |
| A11 | Local NAS/SSH/SMB/printer access | No accidental LAN disruption |
| A12 | Overlapping corporate private CIDR | Explicitly block or respect server routes |
| A13 | Change rule feed while connected | Additions/removals valid; connection need not restart |
| A14 | Update fails midway | Route ownership rollback, old working snapshot intact |
| A15 | Kill/force-exit privileged helper mid-update | Journal recovery and no persistent broken routes |
| A16 | Disconnect when traffic is active | Restore DNS and route state, no app-created routes remain |
| A17 | Sleep, wake, Wi-Fi SSID/gateway switch | Reroute safely or disconnect; no stale physical gateway |
| A18 | Reconnect remote VPN to a different server IP | Endpoint pin updated, old pin removed |
| A19 | Native IPv6 physical default present | IPv4-only mode refuses to claim protected tunnel |
| A20 | Corporate split DNS, mDNS and local printer | No DNS leak or local discovery regression |
| A21 | Install/update/uninstall PKG | Process stopped; helper and launchd correctly removed |
| A22 | macOS 13 / 14 / 15 / 26 compatibility | No API/permission regressions |
| A23 | Test Intel + Apple Silicon | Correct architecture support and code signatures |
| A24 | Dependency and license review | GPL / copyright notices and source available as required |
| A25 | CPU/memory/energy baseline vs OpenVPN Connect | Measured under same server/cipher/traffic |

**No entry above is yet marked as passed by actual hardware testing.**

## Additional release acceptance scenarios (not yet performed)

| ID | Test | Expected |
|---|---|---|
| A26 | Edit .ovpn from native UI | Safe edits saved, previous config archived, still-private 0600 files |
| A27 | Edit .ovpn containing external cert references | Runtime self-contained revision is restorable |
| A28 | Attempt unsafe script directive in editor | Rejected and existing profile preserved |
| A29 | Hostname/profile switch while VPN connected | Existing session unaffected and editable operations blocked |
| A30 | Release update tampered URL/package | Repository URL, Team ID, Gatekeeper verification prevent install |
| A31 | Signed package upgrade with helper still running | Installer refuses replacement without disabling services |
| A32 | CN prefixes overlap on-link public subnet | Existing local route preferred and no conflicting rule installed |
| A33 | IPv6 default appears while split tunnel active | Session is stopped; do not describe polling as a kill switch |
| A34 | Route verification failure after installation | Transaction ownership journal enables rollback |
| A35 | Old VPN process late exit during new session | Old callbacks cannot tear down new process |

## Additional safety regression gates

| ID | Test | Expected |
|---|---|---|
| A36 | Malformed country CIDR overlapping 192.168/16, multicast, CGNAT | Feed rejected, last known-good routes retained |
| A37 | Live feed adds CN CIDR overlapping connected LAN | Effective route diff protects LAN before any add |
| A38 | Large/malicious CIDR feed through root XPC | Input rejected before parsing unbounded entries |
| A39 | Crash helper while OpenVPN child remains alive | New session is blocked pending manual identity verification |
| A40 | Unsigned/lookalike app contacts signed root helper | OS-enforced XPC code requirement rejects peer |
| A41 | Fake helper receives credentials from app | Client-side helper designated requirement rejects fake endpoint |
| A42 | Rule update archives known-good snapshot | Snapshot remains local, 0600, can restore with policy checks |
| A43 | Network diagnostics on corporate split DNS | Only resolver count and interface shown, private domain never logged |

| A44 | Crash after route journal begun event, before route add | Replay marks ambiguous; no automatic delete or new tunnel |
| A45 | Crash after route add, before commit event | Replay marks ambiguous, even if route appears to match physical gateway |
| A46 | Crash after committed add | Replay verifies ownership and removes only confirmed VPN Navigator route |
| A47 | Crash during route deletion | Recovery blocks; no speculative deletion |
| A48 | Helper crash with OpenVPN still alive | No automatic route cleanup or competing child process |

| A49 | Disconnect while active tunnel carries traffic | Confirm child exits BEFORE custom /1 routes are restored |
| A50 | Kill child refuses to exit | Keep active session marker and routing journal; block reconnect |
| A51 | Switch profile from menu/window | Display actual active ID; stop old OpenVPN and confirm disconnect before reconnect |
| A52 | IPv6 CIDR reserved input / country prefix | Reject malformed/special IPv6 networks; no unintended OS route changes |
| A53 | PF anchor syntax in CI | `pfctl -vnf` parses candidate without loading or enabling PF |
| A54 | PF guard active on spare Mac (future) | Prove anchors evaluated, leak-free IPv4/IPv6 and emergency restoration |
| A55 | Signed helper deregistration with unresolved routes | Refuse deregistration; require verified recovery |

| A56 | Managed profile includes local `route` or `redirect-gateway` | Reject conflicting local routing directives before launching OpenVPN |
| A57 | OpenVPN server pushes route and redirect-gateway | Validate suppressive compatibility filters; prove ownership of OS routes |
| A58 | OpenVPN RECONNECTING during China Direct or Full VPN | Stop child before rollback; no automatic unprotected reconnect |
| A59 | IPv6 default and foreign route change during Full VPN | Watchdog rejects unexpected network state |
| A60 | Helper crash after PID record, child already exited | Recovery clears stale markers only when exact PID is absent |
| A61 | Helper crash with alive or reused PID | Recovery does not send signals or clear evidence |
| A62 | Client cert inline data contains directive-like text | Managed routing scanner ignores inline certificate material |

| A63 | Helper restarted with old active.ovpn/PID marker; user clicks Disconnect | No marker deletion or route rollback; only explicit absence-verified recovery can clear evidence |
