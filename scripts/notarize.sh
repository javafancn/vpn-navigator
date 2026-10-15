#!/bin/zsh
# Notarizes both the .app ZIP and the final Developer ID-signed PKG.
set -euo pipefail
cd "${0:A:h}/.."
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE}"
APP="$PWD/dist/VPN Navigator.app"
[[ -d "$APP" ]] || { echo "Build and sign the app first"; exit 1; }
ZIP="$PWD/dist/VPN-Navigator-notarization.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
PKG="$PWD/dist/VPN-Navigator-0.1.0.pkg"
if [[ -f "$PKG" ]]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$PKG"
  xcrun stapler validate "$PKG"
  pkgutil --check-signature "$PKG"
else
  echo "No PKG found. App notarized only; rerun after building a signed PKG."
fi
