# VPN Navigator 0.2 architecture

## Trust boundaries

The SwiftUI app owns UI, per-profile metadata, user Keychain access and unprivileged probes. The signed SMAppService daemon accepts a typed XPC contract only from approved application identities. Clients verify the daemon's designated signing requirement before sending credentials. The daemon verifies the root-owned, sealed application, bundled OpenVPN binary and DNS hook before creating a session.

No GUI path, shell command, script or plugin is accepted for privileged execution. Imported certificate paths are materialized in user space; only validated self-contained text reaches the helper. Passwords and OTP/private-key responses are never included in structured logs or support exports.

## Session lifecycle

One serial helper queue owns the child process, management socket, deadlines, network notifications and routing state. Initial and reconnect attempts have a bounded deadline. Cancel and Quit call the same disconnect path. Old callback identities cannot tear down a new child. A child which cannot be confirmed stopped retains its markers; the code does not send a delayed SIGKILL to an unverified PID.

The single main window can be reopened from the menu bar. Closing it leaves the app running; quitting waits for explicit shutdown, and refuses to silently leave an unresolved protected session.

## Routing and DNS

Managed routing rejects local route overrides and suppresses conflicting pushed routes. These compatibility filters are not a hostile-server security boundary. Route changes are journaled and verified before reporting a protected policy active. On-link LAN prefixes and the VPN endpoint are excluded from country routes.

Before OpenVPN launches, DNSRecoveryJournal snapshots the original primary service. Its UUID is passed to the signed DNS hook, so an interface switch cannot redirect a down-hook onto a different service. The trusted hook invokes the root-only fixed `--commit-dns <utun>` helper mode immediately after changing DNS. The helper later confirms the applied values and actual tunnel identity.

Restoration compares the current property-list values with the recorded original and applied values. Values already restored are left alone; owned applied values can be restored. Another owner's value or an unfinished ambiguous transaction blocks speculative restoration and retains the journal. The synthetic-service CI test never changes an existing network service.

## Optional PF guard and guarded reconnect

PacketFilterGuard loads only `com.apple/000.vpn-navigator`, retaining its own `pfctl -E` reference token and receipt. It accepts only the known Apple root anchor layout (plus the standard scrub anchor), checks ordering and rejects skipped interfaces. It never reloads the host main ruleset or globally disables PF.

The strict policy permits loopback, the pinned numeric IPv4 endpoint, DHCP, explicit local/country exceptions and the actual owned IPv4 tunnel. All other outward IPv4/IPv6 is blocked. Pass states are interface-bound; protection transitions reset existing PF states, explicitly disclosed in the opt-in UI. This affects existing connections and other VPNs, so arbitrary filtering products are not advertised as compatible.

Unexpected failure retains the guard. Explicit Disconnect, safe recovery or maintenance releases only the owned anchor and enable reference after the child, DNS and routes are resolved. A missing token is never permission to globally disable PF.

Managed auto-reconnect additionally requires opt-in and a verified active guard. A bounded 1/2/4 second retry budget permits at most three retries per ten minutes. Each retry confirms old-process exit and DNS/route rollback, keeps PF active, and starts a new owned session using the already pinned server IPv4. It cannot silently reconnect through an unprotected path. Real network/hardware failure injection remains a release gate.

## Diagnostics, rules and delivery

Real probes use fixed system executables with validated arguments or Network.framework TCP connections, all with cancellation and deadlines. DiagnosticEventStore keeps at most 150 predefined timestamped categories in private files. Raw engine output is classified transiently and discarded.

Initial country rules are bundled with source/license metadata and validated before caching. Downloads use bounded streaming and two official GitHub access paths, then CIDR and change-policy validation. A non-root daily agent requests typed live updates before committing a changed cache.

Signed delivery compiles native OpenVPN and static OpenSSL from hash-verified sources for the declared minimum macOS. Architecture-specific installers, sidecar hashes and manifests are generated from Info.plist. Updates accept only the official release path and a matching developer team, then hand the verified package to macOS Installer. Release automation can create a draft; it does not publish an unvalidated production release.

## Remaining validation boundaries

No static or loopback result certifies full traffic leak freedom. Real signed XPC registration, TLS/OTP servers, corporate DNS, physical IPv6, network switching, sleep/wake, multi-VPN scenarios, process crashes, long-duration usage and clean installation must still be recorded. Initial-authentication legacy CRV1 is implemented with bounded rounds; post-connect CRV1 reauthentication, browser/SAML and IPv6 country routing remain unsupported.
