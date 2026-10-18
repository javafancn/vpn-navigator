# Authentication and maintenance follow-up — 2026-10-18

## Delivered

- Legacy dynamic CRV1 for initial authentication: strict flags/base64/UTF-8/length validation, server-decoded username, exact escaped opaque state, next-Need-Auth sequencing, explicit response-free acknowledgement and at most three rounds.
- Static challenge flags 0/1 use SCRV1; flags 2/3 use password-plus-response as defined by the pinned OpenVPN 2.7.8 management protocol. All inputs remain secure even when a server requests visible echo.
- Opaque CRV1 context remains exclusively in the helper's in-memory exchange. SessionReport carries only the challenge identity, prompt and input policy. Neither OTP nor challenge state is written to profiles, Keychain or diagnostics.
- An expected CRV1 initial auth-failure restart retains the same process, original overall deadline and pre-tunnel PF rules. Transport failures and post-connect challenges do not bypass managed reconnect protection.
- The Unix read loop owns its descriptor until shutdown finishes, while writes are bounded. Cancellation wakes a blocked reader and clears pending secrets. Closed connections cannot be reopened or answer stale challenges.
- Session reports explicitly carry pending DNS/route/session recovery evidence. Quit and maintenance remain blocked after process exit until it is resolved; failed snapshots from older helpers are treated conservatively.
- Maintenance verifies helper, rule updater and login startup unregistering; blocks concurrent connection/profile edits and Quit during cleanup; checks scoped Keychain deletion including orphan entries before reporting success.

## Validation

Pure state-machine tests cover valid responses, optional acknowledgements, escaping, replaced/stale IDs, bounded retries, malformed challenges, established-session boundaries and sanitized session payloads. Non-root Unix socket fixtures exercise credential/private-key/static/dynamic exchanges, split UTF-8/CRLF, invalid data and repeated concurrent/idle cancellation on the four macOS runner configurations. Release bundles are checked to exclude the debug fixture entry.

Implementation `7fb2d2deb8502906d1844e110735df0006a5de9b` passed:

- [114 core tests, route ordering and real management socket fixtures on macOS 14, 15, 26 and Intel](https://github.com/javafancn/vpn-navigator/actions/runs/39101779879).
- [Universal native build, real diagnostic probes, debug fixture exclusion and five-workspace captures](https://github.com/javafancn/vpn-navigator/actions/runs/39101779876).
- [Both-architecture engine packaging/minimum-OS audits, synthetic DNS recovery and actual PF blocking/release](https://github.com/javafancn/vpn-navigator/actions/runs/39101779885).

The final follow-up changes only this validation record and checklist formatting. These fixtures do not simulate a successful signed XPC installation, TLS server, real network route or packet-leak acceptance.

## Remaining boundaries

- Post-connect CRV1 renegotiation, browser/SAML and newer web/deferred-auth flows remain unsupported; no browser URL is opened from untrusted management messages.
- Managed routing remains IPv4, with optional experimental physical IPv6 blocking. IPv6 country routing is not implemented.
- Production Developer ID/notarization, signed service installation/removal, real-server MFA, physical IPv4/IPv6 captures, sleep/wake/crash and long-duration hardware acceptance remain required before public release.

Protocol reference: [OpenVPN 2.7.8 management-notes.txt](https://github.com/OpenVPN/openvpn/blob/v2.7.8/doc/management-notes.txt).
