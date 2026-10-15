#!/bin/zsh
# Release gate: only intended for fully signed, independently packaged binaries.
set -euo pipefail
cd "${0:A:h}/.."
APP="$PWD/dist/VPN Navigator.app"
[[ -d "$APP" ]] || { echo "Missing app bundle"; exit 1; }
ENGINE="$APP/Contents/Resources/openvpn"
DNS="$APP/Contents/Resources/macos-dns-updown.sh"
[[ -x "$ENGINE" && -x "$DNS" ]] || { echo "Engine/DNS hook missing"; exit 1; }
[[ -d "$APP/Contents/Frameworks" ]] || { echo "Missing Frameworks directory"; exit 1; }
[[ -f "$APP/Contents/Resources/openvpn-dependencies.json" ]] || { echo "No dependency manifest"; exit 1; }
[[ -s "$APP/Contents/Resources/Sources/OpenVPN-source.tar.gz" ]] || { echo "GPL source missing"; exit 1; }
[[ -s "$APP/Contents/Resources/LICENSES/THIRD_PARTY_NOTICES.txt" ]] || { echo "License notices missing"; exit 1; }


plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchDaemons/"*.plist \
  "$APP/Contents/Library/LaunchAgents/"*.plist
/bin/bash -n "$DNS"
"$ENGINE" --version
codesign --verify --deep --strict --verbose=2 "$APP"
APPID="$(codesign -dv --verbose=2 "$APP" 2>&1 | grep '^Identifier=' | cut -d= -f2)"
[[ "$APPID" == "com.javafancn.vpn-navigator" ]] || { echo "Wrong app identity"; exit 1; }
TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | grep '^TeamIdentifier=' | cut -d= -f2)"
[[ -n "$TEAM" && "$TEAM" != "not set" ]] || { echo "App has no Developer ID Team"; exit 1; }
for entry in VPNNavigatorHelper VPNNavigatorRuleAgent openvpn; do
  [[ -f "$APP/Contents/Resources/$entry" ]] || { echo "Missing $entry"; exit 1; }
  PARTTEAM="$(codesign -dv --verbose=4 "$APP/Contents/Resources/$entry" 2>&1 | grep '^TeamIdentifier=' | cut -d= -f2)"
  [[ "$PARTTEAM" == "$TEAM" ]] || { echo "Team mismatch in $entry"; exit 1; }
done
for dylib in "$APP"/Contents/Frameworks/*.dylib(N); do
  codesign --verify --strict "$dylib"
done

# Verify all linked dylibs resolve to Apple system libraries or vendored copies.
python3 - "$ENGINE" "$APP/Contents/Frameworks" <<'PY'
import pathlib, subprocess, sys
binary, frameworks = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for path in [binary, *frameworks.glob("*.dylib")]:
    deps = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
    for raw in deps:
        name = raw.strip().split(" (")[0]
        if name.startswith(("/System/Library/", "/usr/lib/")):
            continue
        if name.startswith(("@executable_path/../Frameworks/", "@loader_path/")):
            if not (frameworks / pathlib.Path(name).name).exists():
                raise SystemExit(f"Missing dependency: {name} referenced by {path}")
            continue
        raise SystemExit(f"Unresolved dependency: {name} referenced by {path}")
print("Dependency audit passed.")
PY
echo "Release package passes static checks. Physical Mac/VPN traffic tests remain mandatory."
