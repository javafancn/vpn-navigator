# VPN Navigator

A native SwiftUI macOS OpenVPN CLI client project with a per-profile route policy engine.

## Development status (alpha; not yet production ready)

- Native macOS SwiftUI app, menu bar, profiles and diagnostics
- Local profile store; preserve original .ovpn; external relative certificate imports are converted to private runtime copies
- Original / Full VPN / Mainland China IPv4 Direct policies
- Country IPv4 rules with validated updates, CIDR diff and persistence
- Swift helper code for OpenVPN process, Unix management socket, pinned endpoint, route transaction/rollback
- XPC boundary requiring signed Team/allowed app identity
- launchd LaunchAgent for daily IPv4 rule refresh
- Standalone app packaging, signing, notarization and PKG packaging scripts
- Swift macOS CI unit tests and unsigned developer UI-only app build

**Not yet proven or delivered as a production VPN client:** bundled audited OpenVPN binaries and dependent libraries, signed notarized distribution, real root Helper registration, live VPN + DNS/IPv6 integration tests, resilient fail-closed network transitions, full .ovpn directive compatibility, safe automatic kernel upgrades, network traffic leak audit.

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
