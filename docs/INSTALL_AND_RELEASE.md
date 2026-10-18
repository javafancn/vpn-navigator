# Build, install and update VPN Navigator 0.2

## UI development

```sh
swift test
zsh scripts/build-app.sh
```

Without OPENVPN_BIN this produces UI-only preview software. Real privileged operations deliberately require Developer ID identity and a protected `/Applications/VPN Navigator.app` installed through its signed PKG.

## Source-built engine

On a macOS build machine, fetch the official source archives pinned in `Resources/Engine/sources.lock.json` (OpenVPN 2.7.8 and OpenSSL 3.5.9). This does not require Homebrew on an end-user Mac.

```sh
python3 scripts/fetch-engine-sources.py /absolute/engine-sources
```

The JSON output file records exact archive paths, versions and verified SHA256. Set OPENVPN_SOURCE_ARCHIVE, OPENVPN_SOURCE_SHA256, OPENSSL_SOURCE_ARCHIVE and OPENSSL_SOURCE_SHA256 from that file, then:

```sh
ENGINE_OUTPUT_DIR=/absolute/engine-prefix bash scripts/build-openvpn-engine.sh
```

The script builds OpenSSL statically and OpenVPN natively for macOS 13, disables compression and unsupported PKCS11/PAM dependencies, and collects actual upstream license texts under `engine-prefix/share/vpn-navigator/THIRD_PARTY_NOTICES.txt`. Review the notices, source provenance and compile flags before distributing.

## Signed app and installer

Set the source paths/hashes above, OPENVPN_BIN to the source-built `sbin/openvpn`, THIRD_PARTY_NOTICES to the generated notices, and your Developer ID identities:

```sh
DEVELOPER_ID_APPLICATION='Developer ID Application: …' zsh scripts/build-app.sh
NOTARY_KEYCHAIN_PROFILE=your-profile zsh scripts/notarize.sh app
DEVELOPER_ID_INSTALLER='Developer ID Installer: …' zsh scripts/build-pkg.sh
NOTARY_KEYCHAIN_PROFILE=your-profile zsh scripts/notarize.sh pkg
zsh scripts/release-audit.sh
```

Both source archives and notices are embedded before signing. The installer name derives from Info.plist and the actual build architecture, e.g. `VPN-Navigator-0.2.0-arm64.pkg`. Produce separate arm64 and x86_64 installers. The release manifest rejects missing slices or a bundled binary whose minimum macOS exceeds the application's declared minimum; a green UI-only build is insufficient.

See SIGNED_RELEASE_WORKFLOW.md for the manual two-architecture workflow. It can attach signed/notarized packages, hashes and manifests to a draft, and never automatically publishes a production release.

## First use

1. Install the signed PKG into Applications and launch the app.
2. Complete the built-in check for app identity, bundled engine, location, helper approval and profiles.
3. Import .ovpn; nearby certificate files are materialized into a self-contained runtime copy.
4. Enter credentials when requested. Optional Keychain storage applies only to account credentials; private-key and OTP answers are not saved. Static SCRV1/concatenated OTP and initial-authentication CRV1 are supported; dynamic requests are limited to three rounds within the original connection deadline.
5. Select a routing policy. A validated initial China IPv4 snapshot is bundled for offline use; online update and local import remain available.

## Protection and maintenance

Experimental PF protection is an explicit opt-in for managed IPv4 modes. It rejects incompatible host layouts and resets existing connections during protection changes. Original mode follows the validated original profile. Complete the real-server tests before claiming protection guarantees.

Use Settings → Upgrade and Uninstall Preparation to disconnect, recover network ownership and unregister the application's helper, rule updater and login startup. Maintenance blocks new sessions and profile mutations while cleanup is in progress. Keep profiles by default; deleting them is an explicit irreversible checkbox. Upgrade opens a verified same-team PKG in macOS Installer. Removal is completed in Finder; the application does not run an arbitrary root deletion command.

The PKG preinstall guard rejects a live helper or unresolved route, DNS, PF or child-session records. Do not delete recovery journals to force an upgrade. Quit old menu-bar instances before replacing a preview app. Closing its window does not quit the application.
