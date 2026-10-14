#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE}"
APP="$PWD/dist/VPN Navigator.app"
[[ -d "$APP" ]] || { echo "Build and sign the app first."; exit 1; }
ZIP="$PWD/dist/VPN-Navigator-notarization.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
