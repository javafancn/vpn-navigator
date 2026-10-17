#!/bin/zsh
# Release order: notarize app -> build signed PKG -> notarize PKG.
set -euo pipefail
cd "${0:A:h}/.."
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE}"
MODE="${1:-app}"
APP="$PWD/dist/VPN Navigator.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
PKG="$PWD/dist/VPN-Navigator-$VERSION-$(uname -m).pkg"
case "$MODE" in
  app)
    [[ -d "$APP" ]] || { echo "Build and sign the app first"; exit 1; }
    codesign --verify --deep --strict "$APP"
    ZIP="$PWD/dist/VPN-Navigator-notarization.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    ;;
  pkg)
    [[ -f "$PKG" ]] || { echo "Build the signed PKG first"; exit 1; }
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$PKG"
    xcrun stapler validate "$PKG"
    pkgutil --check-signature "$PKG"
    ;;
  *)
    echo "Usage: zsh scripts/notarize.sh app|pkg" >&2
    exit 2
    ;;
esac

