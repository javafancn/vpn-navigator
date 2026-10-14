# Native app packaging and background services

Requires macOS 13+, Xcode/Command Line Tools, a Developer ID signing identity for root helper registration, and a redistributable, reviewed OpenVPN 2.x CLI build.

## Build and test
```shell
swift test
./scripts/build-app.sh
open "dist/VPN Navigator.app"
```

This creates a native .app without invoking Homebrew on end-user machines. An unsigned developer build shows the UI but **cannot install the privileged helper**.

## Bring your own audited OpenVPN binary

Provide a properly packaged OpenVPN 2.x CLI executable and audit its library dependencies before signing:

```shell
OPENVPN_BIN=/path/to/portable/openvpn \
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." \
./scripts/build-app.sh
```

The build script **rejects typical Homebrew-linked binaries**; it does not yet automatically vendor all required TLS/crypto dynamic libraries. Bundling/distributing OpenVPN 2.x requires GPL compliance and reproducible source notices. Do not release the bundle without dependency audit.

## Background services
- LaunchDaemon: `com.javafancn.vpn-navigator.helper`, registered by macOS SMAppService after user approval.
- LaunchAgent: `com.javafancn.vpn-navigator.rules`, runs every 86400 seconds and at login. The user must explicitly register it via the app.
- Only signed clients with the app's signing Team ID and approved bundle identifiers can access the root daemon.
- No shell execution of imported .ovpn directives is allowed; unsupported profiles are rejected.

## Notarize
Once a properly signed app is produced:

```shell
NOTARY_KEYCHAIN_PROFILE=your-keychain-profile ./scripts/notarize.sh
```

Always test install, reconnect, shutdown, sleep/wake, uninstallation, emergency cleanup and both DNS/IPv6 behavior on a disposable test Mac before shipping.

**Known blockers**: external certificate-file profiles are not supported by the strict privileged validator yet; signed distributable OpenVPN CLI binary isn't included; system-route hot update and crash recovery need real macOS integration tests. Not a production release.
