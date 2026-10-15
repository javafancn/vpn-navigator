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

## Engine packaging (maintainer Mac)

Install a verified OpenVPN 2.7.x formula on the **build machine only**, then:

```bash
brew install openvpn
OPENVPN_BIN="$(brew --prefix openvpn)/sbin/openvpn" \
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." \
zsh scripts/build-app.sh
DEVELOPER_ID_INSTALLER="Developer ID Installer: ..." \
zsh scripts/build-pkg.sh
zsh scripts/release-audit.sh
```

`vendor-openvpn.py` recursively copies third-party Mach-O libraries into
`Contents/Frameworks`, rewrites their load paths, runs `openvpn --version`,
and records source paths/checksums in an engine-dependency manifest. Do not
assume the manifest grants any redistribution license. Provide all required
third-party notices, GPL OpenVPN source corresponding to the binary, and
reproducible build instructions with any published installer. Do not release
unsigned files or an unsigned UI-only CI artifact as a working VPN.

`release-audit.sh` checks binaries, identity, Team ID, libraries and plists;
it **cannot** substitute for physical macOS networking, entitlement and
notarization testing.

## Required license materials for signed distribution

The build intentionally refuses to sign a distributable binary without
`OPENVPN_SOURCE_ARCHIVE` (matching the *actual* OpenVPN binary),
`OPENVPN_SOURCE_SHA256`, and a reviewed `THIRD_PARTY_NOTICES` file.
The source archive and notices ship inside the signed app bundle; this is
one part of license compliance, **not** a legal certification. Ensure build
scripts and source for all GPL-covered modifications are also supplied.

```sh
OPENVPN_BIN=/path/to/openvpn \
OPENVPN_SOURCE_ARCHIVE=/path/to/matching-source.tar.gz \
OPENVPN_SOURCE_SHA256="$(shasum -a 256 /path/to/matching-source.tar.gz | cut -d' ' -f1)" \
THIRD_PARTY_NOTICES=/path/to/reviewed-notices.txt \
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." \
zsh scripts/build-app.sh
```

Sign and build PKG, then invoke `scripts/notarize.sh` **after** the PKG
is generated to notarize both the app and installer. For release review run
`zsh scripts/release-audit.sh`, `spctl --assess`, and the real-Mac QA checklist.
