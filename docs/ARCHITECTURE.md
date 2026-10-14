# Architecture & safety boundaries

## This repository's initial implementation

The SwiftPM library (VPNNavigatorCore) provides a validated CIDR parser, policy compiler, profile repository and remote IPv4 rule updater. The SwiftUI app provides a macOS-native, offline-first profile workspace. Neither component silently modifies the machine's routes.

**Not yet implemented:** privileged helper, signed OpenVPN distribution, root-safe configuration sanitizer, Management Interface controller, DNS lifecycle, IPv6 policy, route reconciliation, rollback, notarized installer, automatic rule scheduling. Connection controls are intentionally not wired until a secure helper is present.

## Intended privileged design

1. UI process runs unprivileged; encrypted credentials go to Keychain (not profile metadata).
2. A signed helper registered with SMAppService authenticates callers over XPC.
3. Imported profiles are untrusted data. Reject executable directives (up/down, plugin, script-security changes, etc.) before any privileged run.
4. Helper launches a known signed OpenVPN executable, owns a private management socket and installs routes only through typed validated APIs.
5. Never install a default VPN route before the tunnel and pinned VPN-server endpoint are usable.
6. Preserve server-pushed private network routes and the physical LAN. On conflict, prompt the user.
7. Use snapshots, idempotent incremental route transactions and rollback on failure.
8. No actual LAN/VPN route will be mutated by the current MVP.

## Toolchains

On macOS 13+, build with Xcode command-line tools and Swift 5.9+:
`swift build`, `swift test`, `swift run VPNNavigatorApp`.

macOS app code cannot be compiled or exercised on Linux; run CI and signing tests on a Mac runner. Run `swift test --filter RuleEngineTests` for logic tests.
