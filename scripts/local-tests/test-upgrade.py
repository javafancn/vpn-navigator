#!/usr/bin/env python3
"""Disposable CI only: actual lower-version PKG -> current PKG transition."""
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

APP = Path('/Applications/VPN Navigator.app')
SOURCE = Path('dist/VPN Navigator.app')
MANIFEST = Path('/Library/Application Support/VPNNavigator/Local/manifest.json')


def run(arguments, ok=True):
    command = [str(value) for value in arguments]
    if '/usr/sbin/installer' in command:
        command.insert(command.index('/usr/sbin/installer') + 1, '-dumplog')
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    if ok and result.returncode:
        raise AssertionError('Upgrade fixture failed: ' + command[0] + '\n' + result.stdout + result.stderr)
    return result


def main():
    assert sys.platform == 'darwin' and os.getuid() != 0
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Disposable GitHub macOS runners only'
    info = SOURCE / 'Contents/Info.plist'
    current = plistlib.loads(info.read_bytes())
    version = current['CFBundleShortVersionString']
    previous = '0.8.2'
    assert tuple(map(int, version.split('.'))) > tuple(map(int, previous.split('.')))
    architecture = platform.machine()
    new_package = Path(f'dist/VPN-Navigator-{version}-{architecture}-Local.pkg')
    assert new_package.is_file()
    folder = Path(tempfile.mkdtemp(prefix='vpnnav-upgrade-fixture-', dir='/tmp'))
    try:
        saved = folder / 'current.app'
        run(['ditto', SOURCE, saved])
        try:
            older = dict(current)
            older['CFBundleShortVersionString'] = previous
            older['CFBundleVersion'] = '22'
            info.write_bytes(plistlib.dumps(older))
            run(['codesign', '--force', '--options', 'runtime', '--sign', '-', '--identifier', 'com.javafancn.vpn-navigator', SOURCE])
            run(['zsh', 'scripts/build-local-pkg.sh'])
            prior_package = folder / 'previous-Local.pkg'
            shutil.copy2(f'dist/VPN-Navigator-{previous}-{architecture}-Local.pkg', prior_package)
        finally:
            shutil.rmtree(SOURCE)
            run(['ditto', saved, SOURCE])
        # The synthetic prior uses current source with a real lower app/package
        # version. It exercises Installer version/identity transitions, not
        # compatibility with every historical binary release.
        run(['sudo', '/usr/sbin/installer', '-pkg', prior_package, '-target', '/'])
        assert json.loads(MANIFEST.read_text())['version'] == previous
        run([APP / 'Contents/MacOS/VPNNavigatorApp', '--vpnnav-local-health-check'])
        prior_app = folder / 'previous.app'
        run(['ditto', APP, prior_app])
        run([APP / 'Contents/MacOS/VPNNavigatorApp', '--vpnnav-local-services-self-test'])
        run(['sudo', '/usr/sbin/installer', '-pkg', new_package, '-target', '/'])
        installed = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
        approval = json.loads(MANIFEST.read_text())
        assert installed['CFBundleShortVersionString'] == approval['version'] == version
        assert installed['CFBundleVersion'] == current['CFBundleVersion']
        run([APP / 'Contents/MacOS/VPNNavigatorApp', '--vpnnav-local-health-check'])
        assert run([prior_app / 'Contents/MacOS/VPNNavigatorApp', '--vpnnav-local-health-check'], ok=False).returncode != 0
        print('PASS: actual lower-version PKG upgrade replaces app/approval consistently and rejects the previous app identity.')
    finally:
        for generated in Path('dist').glob(f'VPN-Navigator-{previous}-{architecture}-Local*'):
            generated.unlink()
        run(['sudo', 'rm', '-rf', folder])


if __name__ == '__main__':
    main()
