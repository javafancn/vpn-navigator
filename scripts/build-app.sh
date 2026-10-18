#!/bin/zsh
# Produces a native macOS app bundle from SwiftPM. Does not install root services.
# For actual VPN connectivity, supply a portable, signed OpenVPN 2.x CLI binary.
set -euo pipefail
cd "${0:A:h}/.."

# CI may opt in to a universal UI-only developer bundle. Production
# builds retain the ordinary host architecture unless explicitly requested.
CHANNEL="${VPNNAV_CHANNEL:-preview}"
BUILD_FLAGS=(-c release)
if [[ "$CHANNEL" == local-test ]]; then
  [[ -z "${DEVELOPER_ID_APPLICATION:-}" && "${VPNNAV_BUILD_UNIVERSAL:-0}" != 1 ]] || exit 1
  BUILD_FLAGS+=(--scratch-path .build/local-test -Xswiftc -DVPNNAV_LOCAL_TEST)
fi
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
if [[ "$CHANNEL" == local-test ]]; then
  cp "$BIN/VPNNavigatorLocalSetup" "$APP/Contents/Resources/"
fi
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

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" || "$CHANNEL" == local-test ]]; then
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
  if [[ -n "${OPENSSL_SOURCE_ARCHIVE:-}" ]]; then
    : "${OPENSSL_SOURCE_SHA256:?Set verified OpenSSL source SHA256}"
    printf '%s  %s\n' "$OPENSSL_SOURCE_SHA256" "$OPENSSL_SOURCE_ARCHIVE" | shasum -a 256 --check
    cp "$OPENSSL_SOURCE_ARCHIVE" "$APP/Contents/Resources/Sources/OpenSSL-source.tar.gz"
  fi
  cp "$THIRD_PARTY_NOTICES" "$APP/Contents/Resources/LICENSES/THIRD_PARTY_NOTICES.txt"
  [[ -s "$APP/Contents/Resources/Sources/OpenVPN-source.tar.gz" &&
     -s "$APP/Contents/Resources/LICENSES/THIRD_PARTY_NOTICES.txt" ]] || exit 1

  if [[ "$CHANNEL" == local-test ]]; then
    [[ -z "$(find "$APP/Contents/Frameworks" -name '*.dylib' -print 2>/dev/null)" ]] || { echo 'Local build requires the source-built static OpenSSL engine'; exit 1; }
    for entry in VPNNavigatorHelper VPNNavigatorRuleAgent openvpn VPNNavigatorLocalSetup; do
      case "$entry" in
        VPNNavigatorHelper) ID=com.javafancn.vpn-navigator.helper ;;
        VPNNavigatorRuleAgent) ID=com.javafancn.vpn-navigator.rule-agent ;;
        VPNNavigatorLocalSetup) ID=com.javafancn.vpn-navigator.local-setup ;;
        *) ID=com.javafancn.vpn-navigator.openvpn ;;
      esac
      codesign --force --options runtime --sign - --identifier "$ID" "$APP/Contents/Resources/$entry"
    done
    codesign --force --options runtime --sign - --identifier com.javafancn.vpn-navigator "$APP"
    codesign --verify --deep --strict "$APP"
    echo "Created local test bundle: $APP"
    exit 0
  fi
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

