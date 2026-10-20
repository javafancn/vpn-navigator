#!/bin/bash
# Sourced only from the administrator-approved PKG's private scripts directory.
# Reject existing symlinks/unsafe ownership before payload extraction or execution.
check_local_paths() {
  local path mode
  for path in '/Library' '/Library/Application Support' '/Library/Application Support/VPNNavigator' '/Library/Application Support/VPNNavigator/Local' '/Library/Application Support/VPNNavigator/Local/Payload' '/Library/LaunchDaemons'; do
    [[ ! -L "$path" ]] || { echo 'Unsafe installation symlink' >&2; return 1; }
    if [[ -e "$path" ]]; then
      [[ -d "$path" && "$(/usr/bin/stat -f %u "$path")" == 0 ]] || return 1
      mode="$(/usr/bin/stat -f %Lp "$path")"
      (( (8#$mode & 8#022) == 0 )) || return 1
    fi
  done
  for path in '/Library/Application Support/VPNNavigator/Local/manifest.json' '/Library/Application Support/VPNNavigator/Local/retired-approval.json' '/Library/Application Support/VPNNavigator/Local/install-state.json' '/Library/Application Support/VPNNavigator/Local/Payload/'{VPNNavigatorHelper,VPNNavigatorRuleAgent,VPNNavigatorLocalSetup,openvpn,macos-dns-updown.sh,approval-template.json,VPNNavigator-Uninstall.pkg} '/Library/LaunchDaemons/com.javafancn.vpn-navigator.local-helper.plist'; do
    [[ ! -L "$path" ]] || return 1
    if [[ -e "$path" ]]; then
      [[ -f "$path" && "$(/usr/bin/stat -f %u "$path")" == 0 ]] || return 1
      mode="$(/usr/bin/stat -f %Lp "$path")"
      (( (8#$mode & 8#022) == 0 )) || return 1
    fi
  done
}
check_local_setup() {
  check_local_paths || { echo 'Unsafe existing local installation; preserve it for diagnosis.' >&2; return 1; }
  local expected actual
  expected="$(/bin/cat "$(/usr/bin/dirname "$0")/setup.sha256")"
  actual="$(/usr/bin/shasum -a 256 '/Library/Application Support/VPNNavigator/Local/Payload/VPNNavigatorLocalSetup')"
  [[ "${actual%% *}" == "$expected" ]] || { echo 'Installed setup tool differs from this approved package.' >&2; return 1; }
}
