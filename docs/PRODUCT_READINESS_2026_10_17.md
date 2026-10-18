# Product-readiness implementation — 2026-10-17

## Integration

PRs 8, 9, 10 and 11 were merged into main. PF branch conflicts retained both broad-prefix rejection and validated public-country-prefix restrictions. The next development version is 0.2.0; no production-readiness claim or automatic public release is made.

## Implemented in this round

| Area | Delivered behavior |
| --- | --- |
| Session control | Cancel while connecting/authenticating; bounded helper deadline; single main window; Quit routes through shutdown |
| Authentication | Automatic account prompt, scoped Keychain reuse, encrypted private-key prompt, SCRV1 static OTP, stale challenge IDs rejected |
| Network checks | Actual TCP, system resolver DNS, bounded traceroute, real ICMP latency/loss; cancel stale work |
| Observability | At most 150 private timestamped failure categories; raw output discarded; explicit sanitized support export |
| Rules | Attributed initial offline dataset, validation before cache, streaming download limits, two official access paths, local import, actual cache timestamp |
| DNS recovery | Pinned primary service, write-ahead original state, trusted hook commit, compare-before-restore, conflict preservation |
| Network changes | SystemConfiguration notifications and watchdog verification; ambiguous recovery does not guess ownership |
| PF protection | Default-off experimental runtime anchor, host preflight, own enable token/receipt, interface-bound pass states, IPv4/IPv6 physical egress policy and explicit cleanup |
| Guarded retries | Opt-in only with verified PF; new owned process after old exit/DNS/route cleanup; 1/2/4 second delays, max 3 per 10 minutes |
| User lifecycle | First-use readiness check, connection preferences, login launch, guided upgrade/removal with optional profile deletion |
| Delivery | Source-built static-OpenSSL engine targeting declared macOS, per-architecture PKGs, automatic version naming, correct update architecture choice, source/notice embedding, sidecar audits, manual draft release |

## Automated validation

Current commit status is authoritative. Workflows cover macOS 14, 15, 26 and an Intel runner; Universal UI slices; core positive/negative tests; real loopback TCP/DNS/ping/traceroute and cancellation/deadline; synthetic-service SCDynamicStore ownership restore/conflict; PF syntax and actual single-loopback-port blocking/recovery; engine relocation and source-build deployment metadata.

PF protection changes intentionally reset current network states, including other VPN connections. The opt-in UI discloses this. Unknown host filters/anchor order/skip interfaces are refused; the app never replaces the host root ruleset or globally disables PF.

## External release acceptance still required

- Developer ID Application and Installer certificates and App Store Connect notarization credentials must be configured by the owner in the protected environment.
- Signed SMAppService/XPC installation must be tested using that real identity.
- Actual OpenVPN servers and disposable accounts must validate TLS, key unlock, OTP, three routing modes and guarded retries.
- Packet captures on physical IPv4/IPv6, Wi-Fi/Ethernet changes, sleep/wake and helper/child crashes must establish the protection boundary.
- macOS 13 hardware, long-duration performance/energy behavior, upgrades/removal and actual redistribution materials require recorded review.

## Explicit compatibility limits

The first release scope is managed IPv4. Protected mode blocks physical IPv6; it does not implement IPv6 country routing. Post-connect CRV1 reauthentication, browser/SAML auth, TAP, arbitrary scripts/plugins and hardware PKCS11 are not supported and must not be represented as completed features. The source-built engine intentionally disables compression. Initial-authentication CRV1 and static flags 2/3 were added in the [2026-10-18 follow-up](AUTH_AND_MAINTENANCE_2026_10_18.md).
