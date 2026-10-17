#!/bin/zsh
# Produces a native macOS app bundle from SwiftPM. Does not install root services.
# For actual VPN connectivity, supply a portable, signed OpenVPN 2.x CLI binary.
set -euo pipefail
cd "${0:A:h}/.."

# CI may opt in to a universal UI-only developer bundle. Production
# builds retain the ordinary host architecture unless explicitly requested.
BUILD_FLAGS=(-c release)
if [[ "${VPNNAV_BUILD_UNIVERSAL:-0}" == "1" ]]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
APP="$PWD/dist/VPN Navigator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
  "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/VPNNavigatorApp" "$APP/Contents/MacOS/VPNNavigatorApp"
cp "$BIN/VPNNavigatorHelper" "$APP/Contents/Resources/VPNNavigatorHelper"
cp "$BIN/VPNNavigatorRuleAgent" "$APP/Contents/Resources/VPNNavigatorRuleAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Engine/macos-dns-updown.sh "$APP/Contents/Resources/macos-dns-updown.sh"
chmod 755 "$APP/Contents/Resources/macos-dns-updown.sh"
mkdir -p "$APP/Contents/Resources/LICENSES"
cp LICENSES/OpenVPN-DNS-BSD-2-Clause.txt "$APP/Contents/Resources/LICENSES/"
cp LICENSES/CHNROUTES2_NOTICE.txt "$APP/Contents/Resources/LICENSES/"
cp -R Resources/Rules "$APP/Contents/Resources/Rules"
cp Resources/LaunchDaemons/*.plist "$APP/Contents/Library/LaunchDaemons/"
cp Resources/LaunchAgents/*.plist "$APP/Contents/Library/LaunchAgents/"

if [[ -n "${OPENVPN_BIN:-}" ]]; then
  [[ -x "$OPENVPN_BIN" ]] || { echo "OPENVPN_BIN must name an executable"; exit 1; }
  python3 scripts/vendor-openvpn.py "$OPENVPN_BIN" "$APP"
else
  echo "WARNING: no OPENVPN_BIN supplied. GUI builds, but VPN connections are unavailable."
fi

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  [[ -x "$APP/Contents/Resources/openvpn" ]] || { echo "Signed release requires OPENVPN_BIN"; exit 1; }
  : "${OPENVPN_SOURCE_ARCHIVE:?Signed release requires matching GPLv2 OpenVPN source archive}"
  : "${OPENVPN_SOURCE_SHA256:?Set verified source archive SHA256}"
  : "${THIRD_PARTY_NOTICES:?Signed release requires reviewed dependency license notices}"
  [[ -f "$OPENVPN_SOURCE_ARCHIVE" && -f "$THIRD_PARTY_NOTICES" ]] || {
    echo "Source or third-party license notices missing"; exit 1
  }
  tar -tzf "$OPENVPN_SOURCE_ARCHIVE" >/dev/null || {
    echo "OpenVPN source must be a valid .tar.gz archive"; exit 1
  }
  ENGINE_VERSION="$("$APP/Contents/Resources/openvpn" --version | head -n 1)"
  [[ "$ENGINE_VERSION" == OpenVPN\ 2.7.* ]] || {
    echo "Release requires a reviewed OpenVPN 2.7.x engine for macOS DNS support"; exit 1
  }
  ACTUAL_SOURCE_SHA256="$(shasum -a 256 "$OPENVPN_SOURCE_ARCHIVE" | awk '{print $1}')"
  [[ "$ACTUAL_SOURCE_SHA256" == "$OPENVPN_SOURCE_SHA256" ]] || {
    echo "OpenVPN source archive hash mismatch"; exit 1
  }
  mkdir -p "$APP/Contents/Resources/Sources"
  cp "$OPENVPN_SOURCE_ARCHIVE" "$APP/Contents/Resources/Sources/OpenVPN-source.tar.gz"
  cp "$THIRD_PARTY_NOTICES" "$APP/Contents/Resources/LICENSES/THIRD_PARTY_NOTICES.txt"
  [[ -s "$APP/Contents/Resources/Sources/OpenVPN-source.tar.gz" &&
     -s "$APP/Contents/Resources/LICENSES/THIRD_PARTY_NOTICES.txt" ]] || exit 1

  # Sign relocated libraries first, then executables and the sealed outer bundle.
  for dylib in "$APP"/Contents/Frameworks/*.dylib(N); do
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$dylib"
  done
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

