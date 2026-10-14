#!/bin/zsh
# Produces a native macOS app bundle from SwiftPM. Does not install root services.
# For actual VPN connectivity, supply a portable, signed OpenVPN 2.x CLI binary.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/VPN Navigator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
  "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/VPNNavigatorApp" "$APP/Contents/MacOS/VPNNavigatorApp"
cp "$BIN/VPNNavigatorHelper" "$APP/Contents/Resources/VPNNavigatorHelper"
cp "$BIN/VPNNavigatorRuleAgent" "$APP/Contents/Resources/VPNNavigatorRuleAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/LaunchDaemons/*.plist "$APP/Contents/Library/LaunchDaemons/"
cp Resources/LaunchAgents/*.plist "$APP/Contents/Library/LaunchAgents/"

if [[ -n "${OPENVPN_BIN:-}" ]]; then
  [[ -x "$OPENVPN_BIN" ]] || { echo "OPENVPN_BIN must name an executable"; exit 1; }
  # Reject common non-portable Homebrew dependency paths; package dependencies separately.
  if otool -L "$OPENVPN_BIN" | grep -E '/opt/homebrew/|/usr/local/opt/|/usr/local/Cellar/' ; then
    echo "Cannot bundle Homebrew-linked dynamic libraries as a standalone application."
    echo "Build/link a redistributable OpenVPN binary first; do not overwrite system libraries."
    exit 1
  fi
  cp "$OPENVPN_BIN" "$APP/Contents/Resources/openvpn"
else
  echo "WARNING: no OPENVPN_BIN supplied. GUI builds, but VPN connections are unavailable."
fi

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  # Explicit sign order: nested tools, then outer bundle. Identifiers are checked by PeerVerifier.
  for entry in VPNNavigatorHelper VPNNavigatorRuleAgent openvpn; do
    [[ -f "$APP/Contents/Resources/$entry" ]] || continue
    case "$entry" in
      VPNNavigatorRuleAgent) ID="com.javafancn.vpn-navigator.rule-agent" ;;
      VPNNavigatorHelper) ID="com.javafancn.vpn-navigator.helper" ;;
      *) ID="com.javafancn.vpn-navigator.openvpn" ;;
    esac
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
      --identifier "$ID" "$APP/Contents/Resources/$entry"
  done
  codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "Unsigned developer bundle: privileged SMAppService helper cannot be registered."
fi

echo "Created: $APP"
