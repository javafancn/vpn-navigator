#!/bin/zsh
# Produces a root-owned signed installer from a previously signed native .app.
set -euo pipefail
cd "${0:A:h}/.."
: "${DEVELOPER_ID_INSTALLER:?Set DEVELOPER_ID_INSTALLER to a valid Developer ID Installer identity}"
APP="$PWD/dist/VPN Navigator.app"
[[ -d "$APP" ]] || { echo "Build the signed native app first."; exit 1; }
[[ -x "$APP/Contents/Resources/openvpn" ]] || { echo "Missing vendored signed OpenVPN binary."; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "App code signature invalid"; exit 1; }
xcrun stapler validate "$APP" || {
  echo "Staple and verify the notarized .app before building a PKG"
  echo "Run NOTARY_KEYCHAIN_PROFILE=... zsh scripts/notarize.sh app"
  exit 1
}

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Applications"
ditto "$APP" "$STAGING/Applications/VPN Navigator.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && ( "$ARCH" == arm64 || "$ARCH" == x86_64 ) ]] || exit 1
# PKG installer assigns root ownership at installation (inspect on a test machine).
pkgbuild --root "$STAGING" \
    --install-location / \
    --identifier com.javafancn.vpn-navigator.pkg \
    --version "$VERSION" \
    --ownership recommended \
    --scripts "$PWD/scripts/pkg-scripts" \
    --sign "$DEVELOPER_ID_INSTALLER" \
    "$PWD/dist/VPN-Navigator-$VERSION-$ARCH.pkg"
echo "Created: $PWD/dist/VPN-Navigator-$VERSION-$ARCH.pkg"

