#!/usr/bin/env python3
"""Disposable runners only: persisted PKG checkpoints, no production fault flag."""
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

APP = Path('/Applications/VPN Navigator.app')
BASE = Path('/Library/Application Support/VPNNavigator/Local')
STATE = BASE / 'install-state.json'
PAYLOAD = BASE / 'Payload'
LABEL = 'system/com.javafancn.vpn-navigator.local-helper'
EXECUTABLE = APP / 'Contents/MacOS/VPNNavigatorApp'
POSTINSTALL = Path('scripts/local-pkg-scripts/postinstall')


def run(arguments, ok=True, timeout=180):
    result = subprocess.run([str(x) for x in arguments], capture_output=True, text=True, timeout=timeout)
    if ok and result.returncode:
        raise AssertionError('Interrupted-install fixture command failed: ' + str(arguments[0]) + '\n' + result.stdout + result.stderr)
    return result


def health(expected=True):
    result = run([EXECUTABLE, '--vpnnav-local-health-check'], ok=False)
    assert (result.returncode == 0) == expected, 'Unexpected client trust at installer checkpoint'


def state(expected_phase, repair=True):
    report = json.loads(run([EXECUTABLE, '--vpnnav-local-installation-state']).stdout)
    assert report['pending'] and report['phase'] == expected_phase
    assert report['repairAvailable'] == repair, 'UI repair eligibility was incorrect'


def main():
    assert sys.platform == 'darwin' and os.getuid() != 0
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Disposable GitHub macOS runners only'
    health()
    version = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    package = Path(f'dist/VPN-Navigator-{version}-{platform.machine()}-Local.pkg')
    assert package.is_file() and not STATE.exists()
    folder = Path(tempfile.mkdtemp(prefix='vpnnav-install-checkpoints-', dir='/tmp'))
    source_script = POSTINSTALL.read_bytes()
    originals = list(Path('dist').glob(f'VPN-Navigator-{version}-{platform.machine()}-Local*'))
    sentinel = Path.home() / 'Library/Application Support/VPNNavigator/Profiles' / ('repair-' + uuid.uuid4().hex + '.txt')
    sentinel.parent.mkdir(parents=True, exist_ok=True)
    sentinel.write_text(uuid.uuid4().hex)
    sentinel.chmod(0o600)
    sentinel_bytes = sentinel.read_bytes()
    try:
        probe = folder / 'PendingClient'
        run(['swiftc', '-swift-version', '5', 'scripts/local-tests/PendingClient.swift', '-o', probe])
        run(['codesign', '--force', '--options', 'runtime', '--sign', '-', '--identifier', 'com.javafancn.vpn-navigator', probe])
        signature = run(['codesign', '-dv', '--verbose=4', probe])
        cdhash = next(line.split('=', 1)[1] for line in signature.stderr.splitlines() if line.startswith('CDHash='))

        def approved_probe(accepted):
            manifest = BASE / 'manifest.json'
            saved = manifest.read_bytes()
            temporary = folder / 'probe-approval.json'
            approval = json.loads(saved)
            approval['binaries']['app']['cdhash'] = cdhash
            approval['binaries']['app']['sha256'] = hashlib.sha256(probe.read_bytes()).hexdigest()
            temporary.write_text(json.dumps(approval))
            run(['sudo', 'cp', temporary, manifest])
            try:
                assert (run([probe], ok=False).returncode == 0) == accepted, 'Server pending-install policy did not match expectation'
            finally:
                temporary.write_bytes(saved)
                run(['sudo', 'cp', temporary, manifest])

        approved_probe(True)
        for original in originals:
            shutil.copy2(original, folder / original.name)
        prefix = '''#!/bin/bash
set -euo pipefail
source "$(/usr/bin/dirname "$0")/guard"
check_local_setup
BASE='/Library/Application Support/VPNNavigator/Local'
'''
        fixtures = {
            'preparing': prefix + 'exit 37\n',
            # Feed an inconsistent typed template to the actual production
            # setup, exercising its failure handler rather than a test switch.
            'repairRequired': prefix + '''/usr/bin/plutil -replace version -string 0.0.0 "$BASE/Payload/approval-template.json"
/usr/bin/plutil -convert json "$BASE/Payload/approval-template.json"
exec "$BASE/Payload/VPNNavigatorLocalSetup" install
''',
            # Model death after publishing approval + launchd job but before
            # the setup's health/commit step. This is a controlled checkpoint,
            # not a claim to have simulated a hardware reboot or power loss.
            'verifying': prefix + '''/bin/cp "$BASE/Payload/approval-template.json" "$BASE/manifest.json"
/usr/bin/plutil -replace ownerUID -integer "$(/usr/bin/stat -f %u /dev/console)" "$BASE/manifest.json"
/usr/bin/plutil -convert json "$BASE/manifest.json"
/bin/chmod 644 "$BASE/manifest.json"
/usr/bin/plutil -replace phase -string verifying "$BASE/install-state.json"
/usr/bin/plutil -convert json "$BASE/install-state.json"
PLIST='/Library/LaunchDaemons/com.javafancn.vpn-navigator.local-helper.plist'
/usr/bin/plutil -create xml1 "$PLIST"
/usr/bin/plutil -insert Label -string com.javafancn.vpn-navigator.local-helper "$PLIST"
/usr/bin/plutil -insert ProgramArguments -xml '<array><string>/Library/Application Support/VPNNavigator/Local/Payload/VPNNavigatorHelper</string></array>' "$PLIST"
/usr/bin/plutil -insert MachServices -xml '<dict><key>com.javafancn.vpn-navigator.helper</key><true/></dict>' "$PLIST"
/usr/bin/plutil -insert RunAtLoad -bool YES "$PLIST"
/bin/chmod 644 "$PLIST"
/bin/launchctl enable system/com.javafancn.vpn-navigator.local-helper
/bin/launchctl bootstrap system "$PLIST"
exit 37
'''
        }
        for phase, content in fixtures.items():
            run([EXECUTABLE, '--vpnnav-local-services-self-test'])
            try:
                POSTINSTALL.write_text(content)
                run(['zsh', 'scripts/build-local-pkg.sh'])
                fault_package = folder / (phase + '-fixture.pkg')
                shutil.copy2(package, fault_package)
            finally:
                POSTINSTALL.write_bytes(source_script)
                for original in originals:
                    shutil.copy2(folder / original.name, original)
            assert run(['sudo', '/usr/sbin/installer', '-pkg', fault_package, '-target', '/'], ok=False).returncode != 0
            assert STATE.exists(), 'Failed package lost the transaction barrier'
            if phase == 'preparing':
                saved_setup = folder / 'held-setup'
                run(['sudo', 'mv', PAYLOAD / 'VPNNavigatorLocalSetup', saved_setup])
                try:
                    assert run(['sudo', '/usr/sbin/installer', '-pkg', PAYLOAD / 'VPNNavigator-Uninstall.pkg', '-target', '/'], ok=False).returncode != 0
                    assert STATE.exists() and BASE.exists(), 'Missing setup was mistaken for a complete uninstall'
                finally:
                    run(['sudo', 'mv', saved_setup, PAYLOAD / 'VPNNavigatorLocalSetup'])
                # Same version/build but a different valid app identity models
                # an incomplete replacement. Repair must restore package code,
                # rather than only rewrite its approval around unknown files.
                run(['sudo', '/usr/libexec/PlistBuddy', '-c', 'Add :VPNNavRepairFixture bool true', APP / 'Contents/Info.plist'])
                run(['sudo', 'codesign', '--force', '--options', 'runtime', '--sign', '-', '--identifier', 'com.javafancn.vpn-navigator', APP])
            state(phase)
            health(False)
            assert run(['sudo', '/usr/sbin/installer', '-pkg', PAYLOAD / 'VPNNavigator-Uninstall.pkg', '-target', '/'], ok=False).returncode != 0
            assert STATE.exists() and APP.exists(), 'Incomplete uninstall destroyed repair evidence'
            if phase == 'verifying':
                # Only the approved root setup can health-check before commit.
                run(['sudo', PAYLOAD / 'VPNNavigatorLocalSetup', 'health'])
                approved_probe(False)
                run(['sudo', PAYLOAD / 'VPNNavigatorLocalSetup', 'health'])
                assert run(['launchctl', 'print', LABEL], ok=False).returncode == 0
                checkpoint = STATE.read_bytes()
                journal = Path('/var/run/vpn-navigator/dns.journal')
                assert run(['sudo', '/bin/test', '-e', journal], ok=False).returncode != 0
                run(['sudo', 'mkdir', '-p', journal.parent])
                run(['sudo', 'touch', journal])
                try:
                    assert run(['sudo', '/usr/sbin/installer', '-pkg', package, '-target', '/'], ok=False).returncode != 0
                    assert STATE.read_bytes() == checkpoint
                    assert run(['sudo', '/bin/test', '-e', journal], ok=False).returncode == 0
                    assert run(['launchctl', 'print', LABEL], ok=False).returncode == 0, 'Repair stopped service before checking network evidence'
                finally:
                    run(['sudo', 'rm', journal])
                # Corrupt/symlink markers never authorize UI exit or repair.
                valid = folder / 'saved-state.json'
                valid.write_bytes(checkpoint)
                run(['sudo', 'rm', STATE])
                run(['sudo', 'ln', '-s', valid, STATE])
                state('none', repair=False)
                assert run(['sudo', '/usr/sbin/installer', '-pkg', package, '-target', '/'], ok=False).returncode != 0
                assert valid.read_bytes() == checkpoint
                run(['sudo', 'rm', STATE])
                run(['sudo', 'cp', valid, STATE])
                run(['sudo', 'chmod', '644', STATE])
                run(['sudo', 'chmod', 'o+w', STATE])
                state('none', repair=False)
                assert run(['sudo', '/usr/sbin/installer', '-pkg', package, '-target', '/'], ok=False).returncode != 0
                run(['sudo', 'chmod', 'o-w', STATE])
            run(['sudo', '/usr/sbin/installer', '-pkg', package, '-target', '/'])
            assert not STATE.exists(), 'Health-checked installation did not commit'
            health()
            assert 'VPNNavRepairFixture' not in plistlib.loads((APP / 'Contents/Info.plist').read_bytes()), 'Same-version repair retained unapproved app code'
            assert sentinel.read_bytes() == sentinel_bytes, 'Repair changed user profiles'
            print('PASS: ' + phase + ' checkpoint blocks ordinary trust, exposes repair, preserves profiles and repairs through administrator PKG.')
        assert hashlib.sha256(package.read_bytes()).digest() == hashlib.sha256((folder / package.name).read_bytes()).digest()
        print('PASS: original candidate packages restored; no fault package is uploaded.')
    finally:
        POSTINSTALL.write_bytes(source_script)
        for original in originals:
            backup = folder / original.name
            if backup.exists():
                shutil.copy2(backup, original)
        sentinel.unlink(missing_ok=True)
        run(['sudo', 'rm', '-rf', folder])


if __name__ == '__main__':
    main()
