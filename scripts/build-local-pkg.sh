#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
APP="$PWD/dist/VPN Navigator.app"
[[ -x "$APP/Contents/Resources/VPNNavigatorLocalSetup" ]] || exit 1
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Applications" "$STAGING/Library/Application Support/VPNNavigator/Local/Payload"
ditto "$APP" "$STAGING/Applications/VPN Navigator.app"
PAYLOAD="$STAGING/Library/Application Support/VPNNavigator/Local/Payload"
for entry in VPNNavigatorHelper VPNNavigatorRuleAgent openvpn VPNNavigatorLocalSetup macos-dns-updown.sh; do
  cp "$APP/Contents/Resources/$entry" "$PAYLOAD/$entry"
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
"$APP/Contents/Resources/VPNNavigatorLocalSetup" template "$APP" "$PAYLOAD" "$VERSION"
chmod -R go-w "$STAGING/Library"
mkdir -p dist
pkgbuild --root "$STAGING" --install-location / --ownership recommended \
  --identifier com.javafancn.vpn-navigator.local --version "$VERSION" \
  --scripts scripts/local-pkg-scripts "dist/VPN-Navigator-$VERSION-$(uname -m)-Local.pkg"
