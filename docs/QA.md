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

| A64 | OpenVPN DNS vars file contains shell metacharacters / control characters | Reject without evaluating any shell commands; no root DNS changes |
| A65 | Management credentials contain CR/NUL/Unicode separators | Reject before management socket is opened |
| A66 | Full VPN gateway or tunnel interface changes after CONNECTED | Watchdog detects path change; managed session terminates |
| A67 | China Direct hot rule update changes routed sample unexpectedly | Fail update, disconnect and retain route journal until verified cleanup |

| A68 | OpenVPN passes malicious DNS environment values without a vars file | Reject before constructing scutil command text |

| A69 | DNS script obtains its lock on a shared world-writable path | Require root-private runtime directory; reject unsafe owner or mode |
| A70 | PF preview receives a /0 or private geographic exception | Reject invalid policy before producing an apparently restrictive guard |


## 0.2 implementation gates (record actual evidence before production publication)

| ID | Scenario | Expected |
| --- | --- | --- |
| A71 | Cancel during resolve/auth/key/OTP prompt | Old attempt cannot restart or overwrite the cancelled session |
| A72 | No account credentials in Keychain | Automatic account prompt; cancellation starts no helper child |
| A73 | Static OTP / encrypted private key | Correct bounded management response; secret absent from all reports |
| A74 | Connection deadline and repeated reconnect events | One bounded deadline; repeated events cannot extend it indefinitely |
| A75 | DNS primary service changes mid-session | Down-hook targets original service; another owner's values are preserved |
| A76 | Crash after DNS hook applies but before CONNECTED | Committed owned values remain recoverable from root-private journal |
| A77 | Compatible PF host, then early-pass/skip modification | Reject unsupported layout; no root ruleset replacement |
| A78 | Existing tunnel PF states when tunnel vanishes | Interface-bound states cannot float to physical egress; capture packets |
| A79 | Protected reconnect fails or user cancels its delay | Guard retained on failure; explicit cancel prevents all later retries |
| A80 | Cold start without Internet | Bundled initial rules validate and cache without downloading |
| A81 | Oversized/redirected/invalid feed | Streaming cancellation; old rules remain intact |
| A82 | Upgrade/uninstall with DNS/PF journals | Refuse upgrade until explicit safe recovery resolves ownership |
| A83 | Native arm64 / x86_64 source engine | No external brew dylibs; actual binary deployment targets match app minimum |
| A84 | Architecture-specific release assets | Updater selects the current architecture or an explicitly universal package |

Automated loopback and synthetic-service tests exercise a subset of these paths. They do not mark the corresponding real-server/physical-network acceptance as passed.


## Authentication and maintenance follow-up (2026-10-18)

| ID | Exercise | Required result |
| --- | --- | --- |
| A85 | Initial CRV1 challenge, with/without R; repeated factors | Wait for next Need Auth, use server-decoded username and exact opaque state; explicit acknowledgement if no response; at most three challenges in the original attempt deadline |
| A86 | Bad flags/base64/control characters/UTF-8; replaced challenge or duplicate reply | Reject or invalidate; never reuse the saved password as an OTP; no opaque context in SessionReport or support exports |
| A87 | CRV1 auth-failure restart vs transport reconnect | Only the initial pending CRV1 auth-failure is treated as authentication; TLS/ping/transport failures and post-connect challenges retain fail-closed reconnect policy |
| A88 | Static challenge flags 0–3 over real Unix socket | 0/1 use SCRV1; 2/3 concatenate exactly and escape management quoting; always secure user input |
| A89 | Cancel while receiving fragments or waiting for challenge | Reader wakes, exactly one exit callback, no stale response; descriptor closed by its reader; debug test entry absent from release helper |
| A90 | Maintenance with login startup, pending service approval or Keychain error | Stop all three app services, block concurrent connection/profile edits and Quit during cleanup; never claim deletion or preparation succeeded on partial failure |
| A91 | Child exited but DNS/route journals remain; legacy failed snapshot | Quit/maintenance stay blocked; an explicit recovered report clears the gate |

`python3 scripts/test-management-socket.py "$(swift build --show-bin-path)/VPNNavigatorHelper"` runs non-root local fixtures without OpenVPN, route, DNS or PF changes. These fixtures validate protocol I/O and cancellation, not real TLS-server compatibility. A85/A87/A90/A91 still require signed application/server acceptance on a disposable Mac.
