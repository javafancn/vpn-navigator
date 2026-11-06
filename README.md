<p align="center">
  <img src="Resources/Branding/AppIcon.png" width="128" height="128" alt="VPN Navigator logo">
</p>
<h1 align="center">VPN Navigator</h1>

<p align="center">A native OpenVPN workspace for macOS.</p>
<p align="center">
  <a href="https://github.com/javafancn/vpn-navigator/releases/tag/v1.0.0"><img src="https://img.shields.io/badge/version-1.0.0-2563eb" alt="Version 1.0.0"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-111827" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-supported-16a34a" alt="Apple Silicon and Intel">
  <a href="https://github.com/javafancn/vpn-navigator/actions/workflows/swift.yml"><img src="https://github.com/javafancn/vpn-navigator/actions/workflows/swift.yml/badge.svg" alt="Swift core tests"></a>
</p>
<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a><br>
  <a href="https://github.com/javafancn/vpn-navigator/releases/latest">Download</a> ·
  <a href="docs/README.md">Documentation</a> ·
  <a href="docs/RELEASE_NOTES_1_0_0.md">Release notes</a> ·
  <a href="https://github.com/javafancn/vpn-navigator/issues">Report an issue</a>
</p>

Manage OpenVPN profiles, choose where traffic goes, and inspect your connection from a native macOS app. Keep the VPN running in the menu bar, with live tunnel speeds and quick profile access. The interface supports English and Simplified Chinese.

## Download and connect

Get **1.0.0** from [GitHub Releases](https://github.com/javafancn/vpn-navigator/releases/latest). Choose the archive for your Mac:

| Mac | Download |
| --- | --- |
| Apple Silicon (M-series) | `VPN-Navigator-1.0.0-Apple-Silicon-arm64.zip` |
| Intel | `VPN-Navigator-1.0.0-Intel-x86_64.zip` |

Each archive contains the OpenVPN engine, installer, uninstaller, SHA-256 checksums, build provenance and installation instructions. These are **local-test builds: ad-hoc signed and not Apple notarized**. Administrator approval pins the installed code identity. No Homebrew is needed on the user's Mac. See [installation and removal](docs/LOCAL_TEST_INSTALLATION.md) for the full procedure.

1. If updating a connection-capable installation, complete **Settings & Maintenance → Upgrade & Uninstall Preparation** in the old app, then quit it.
2. Unzip the archive, verify the included SHA-256 checksums and run the installer for your architecture.
3. Open VPN Navigator from Applications and complete the built-in installation checks.
4. Import your `.ovpn` profile, choose a routing mode and connect. Supply credentials when requested.

Closing the window keeps the VPN running in the menu bar. **Open Main Window** restores it; **Quit / ⌘Q** disconnects, verifies network recovery and stops background work.

## What you can do

| Workspace | Highlights |
| --- | --- |
| Connection overview | Live tunnel speeds, 60-second traffic graph, transfer totals, verified routing state and recovery actions. |
| Profile library | Import from Finder or drag and drop; search, groups, favorites, notes, safe updates, version history and encrypted backups. |
| Routing | Original, Global VPN and Mainland China Direct modes; IPv4/IPv6 rules, per-profile exceptions and route explanations. |
| Diagnostics | DNS, TCP, bounded traceroute and ping, public IPv4/IPv6 egress checks and redacted diagnostic exports. |
| Settings & maintenance | Optional smart connection, status notifications, login startup, interface language and upgrade/removal preparation. |

- **Authentication:** optional Keychain storage for account credentials, private-key passphrases, static OTP and initial CRV1 dynamic challenges.
- **Quick access:** ⇧⌘P opens profile search; ⌘1–5 switches workspaces. Keyboard navigation, VoiceOver labels and Increase Contrast are supported.
- **DNS and recovery:** Mainland China Direct uses split DNS; Global VPN uses VPN DNS. Ownership records support guarded DNS and route restoration.
- **Connection history:** local session timelines and observed quality, with configurable retention and clearing controls.

## Routing at a glance

| Mode | Behavior |
| --- | --- |
| Original | Follows the validated OpenVPN profile. |
| Global VPN | Routes managed default traffic through the VPN. |
| Mainland China Direct | Sends regional IPv4/IPv6 destinations directly and other default traffic through the VPN, according to the tunnel's address families. Listed domestic domains use direct DNS. |

Custom direct/VPN rules support both address families. See [dual stack](docs/DUAL_STACK.md), [routing tools](docs/ROUTING_TOOLS.md) and [split DNS](docs/SPLIT_DNS_AND_DISCONNECT.md) for constraints and recovery behavior.

## Build from source

Requires **macOS 13+** and **Swift 5.9+** with a compatible macOS SDK and XCTest toolchain.

```sh
swift test
zsh scripts/build-app.sh
```

Without `OPENVPN_BIN`, this creates a UI-only preview. For a connection-capable build, follow [local-test installation](docs/LOCAL_TEST_INSTALLATION.md) or the [source-engine and signed-build guide](docs/INSTALL_AND_RELEASE.md). The [installer workflow](https://github.com/javafancn/vpn-navigator/actions/workflows/package-installers.yml) builds both architectures. Developer ID signing and notarization use a [separate workflow](docs/SIGNED_RELEASE_WORKFLOW.md).

## Documentation

| Start here | Reference |
| --- | --- |
| Install, update or uninstall | [Local installation](docs/LOCAL_TEST_INSTALLATION.md) |
| Organize and migrate profiles | [Profile library](docs/PROFILE_LIBRARY.md) · [Encrypted backups](docs/ENCRYPTED_BACKUP.md) · [Health and updates](docs/PROFILE_HEALTH_AND_UPDATES.md) |
| Configure routing and automation | [Routing tools](docs/ROUTING_TOOLS.md) · [Smart connection](docs/SMART_CONNECTION.md) |
| Investigate connection problems | [Startup diagnostics](docs/OPENVPN_STARTUP.md) · [Web latency](docs/WEB_LATENCY_AND_OVERNIGHT.md) · [Public egress](docs/PUBLIC_EGRESS.md) |
| Contribute or verify a release | [Architecture](docs/ARCHITECTURE.md) · [QA checklist](docs/QA.md) · [1.0.0 notes](docs/RELEASE_NOTES_1_0_0.md) |

The [complete documentation index](docs/README.md) includes implementation notes and earlier validation records. Most detailed documents are currently in Chinese.

## Security and compatibility

Profiles must include `remote-cert-tls server` or an exact `verify-x509-name` constraint before connection. Legacy profiles can still be imported and edited. Unsupported scripts/plugins, TAP, hardware PKCS11, SAML/browser authentication and in-session CRV1 reauthentication are outside the current scope.

**PF disconnect protection is experimental and off by default.** It requires a compatible system PF layout; protection changes reset existing network connections. Full physical-network leak acceptance remains incomplete. A 1.0.0 version number does not imply Apple notarization or completion of every real-network acceptance test. Current limits and the remaining acceptance matrix are recorded in the [release notes](docs/RELEASE_NOTES_1_0_0.md) and [QA checklist](docs/QA.md).

Recovery changes only DNS, routes and PF resources whose app ownership can be confirmed. Profiles may contain private keys; keep real profiles, passwords and signing certificates out of Git and issue reports.

## Acknowledgments and licenses

Regional rules originate from [misakaio/chnroutes2](https://github.com/misakaio/chnroutes2), with CC BY-SA 2.0 attribution and snapshot provenance retained in [Resources/Rules](Resources/Rules/README.md). Engine builds bundle original OpenVPN/OpenSSL licenses and corresponding source archives. See [LICENSES](LICENSES) and the dependency notices included with each build.
