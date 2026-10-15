# VPN Navigator

Native macOS VPN profile manager and planned lightweight OpenVPN CLI client.

## Current status — foundation, NOT a production VPN client

- [x] SwiftUI-native macOS window and menu-bar entry
- [x] Import/store/browse .ovpn profiles without mutating originals
- [x] Per-profile network policy selector
- [x] Download, validate, cache Mainland China IPv4 CIDR rules
- [x] Generate a split-tunnel OpenVPN configuration for inspection/export
- [x] Swift core unit tests
- [ ] Authenticated privileged helper and safe OpenVPN CLI integration
- [ ] Connected VPN control (connect/disconnect/credentials)
- [ ] System route application, LAN preservation, live updates and rollback
- [ ] DNS/IPv6 leak safeguards and a safe installer
- [ ] macOS real-device integration testing and notarization

The UI never claims a VPN connection is active. It does not change system networking.

## Build

Requires macOS 13+, Xcode with Swift 5.9 or newer:

```shell
swift test
swift run VPNNavigatorApp
```

This first build is a SwiftPM executable for development. A signed .app bundle, launch daemon and embedded OpenVPN binary are not yet supplied.

## Safety

Treat every imported .ovpn as untrusted; OpenVPN supports executable hooks/plugins. Do **not** feed arbitrary profiles to sudo/root. Only connect them through a future validated helper. Profiles can contain private keys; never commit .ovpn files to git. This project stores source files in user-private application support and does not send them to a server.

Rule source: https://github.com/misakaio/chnroutes2 (follow the upstream dataset's license/attribution terms).

OpenVPN Community has its own GPL licensing obligations for distribution.
