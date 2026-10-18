#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
APP="$PWD/dist/VPN Navigator.app"
[[ -x "$APP/Contents/Resources/VPNNavigatorLocalSetup" ]] || exit 1
STAGING="$(mktemp -d)"
INSTALL_SCRIPTS="$(mktemp -d)"
UNINSTALL_SCRIPTS="$(mktemp -d)"
trap 'rm -rf "$STAGING" "$INSTALL_SCRIPTS" "$UNINSTALL_SCRIPTS"' EXIT
cp scripts/local-pkg-scripts/* "$INSTALL_SCRIPTS/"
uname -m > "$INSTALL_SCRIPTS/architecture"
mkdir -p "$STAGING/Applications" "$STAGING/Library/Application Support/VPNNavigator/Local/Payload"
ditto "$APP" "$STAGING/Applications/VPN Navigator.app"
PAYLOAD="$STAGING/Library/Application Support/VPNNavigator/Local/Payload"
for entry in VPNNavigatorHelper VPNNavigatorRuleAgent openvpn VPNNavigatorLocalSetup macos-dns-updown.sh; do
  cp "$APP/Contents/Resources/$entry" "$PAYLOAD/$entry"
done
cp scripts/local-uninstall-scripts/* "$UNINSTALL_SCRIPTS/"
for scripts in "$INSTALL_SCRIPTS" "$UNINSTALL_SCRIPTS"; do
  cp scripts/local-install-guard.sh "$scripts/guard"
  shasum -a 256 "$PAYLOAD/VPNNavigatorLocalSetup" | awk '{print $1}' > "$scripts/setup.sha256"
done
pkgbuild --nopayload --identifier com.javafancn.vpn-navigator.local-uninstall --version 1.0 --scripts "$UNINSTALL_SCRIPTS" "$PAYLOAD/VPNNavigator-Uninstall.pkg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
"$APP/Contents/Resources/VPNNavigatorLocalSetup" template "$APP" "$PAYLOAD" "$VERSION"
chmod -R go-w "$STAGING/Library"
mkdir -p dist
pkgbuild --analyze --root "$STAGING" "$INSTALL_SCRIPTS/components.plist"
python3 - "$INSTALL_SCRIPTS/components.plist" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
for component in components:
    component["BundleIsRelocatable"] = False
path.write_bytes(plistlib.dumps(components))
PY
pkgbuild --root "$STAGING" --component-plist "$INSTALL_SCRIPTS/components.plist" --install-location / --ownership recommended \
  --identifier com.javafancn.vpn-navigator.local --version "$VERSION" \
  --scripts "$INSTALL_SCRIPTS" "dist/VPN-Navigator-$VERSION-$(uname -m)-Local.pkg"
cp "$PAYLOAD/VPNNavigator-Uninstall.pkg" "dist/VPN-Navigator-$VERSION-$(uname -m)-Local-Uninstall.pkg"

(cd dist && shasum -a 256 *-Local.pkg *-Local-Uninstall.pkg > "VPN-Navigator-$VERSION-$(uname -m)-Local-SHA256.txt")
cp "$PAYLOAD/approval-template.json" "dist/VPN-Navigator-$VERSION-$(uname -m)-Local-manifest.json"
