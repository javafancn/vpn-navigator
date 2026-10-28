#!/usr/bin/env python3
"""Disposable CI Macs only: real launchd/XPC trust, no VPN/network changes."""
import os
import json
import hashlib
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid
import ipaddress

APP = pathlib.Path('/Applications/VPN Navigator.app')
BASE = pathlib.Path('/Library/Application Support/VPNNavigator/Local')
PAYLOAD = BASE / 'Payload'
LABEL = 'com.javafancn.vpn-navigator.local-helper'
PLIST = pathlib.Path('/Library/LaunchDaemons/' + LABEL + '.plist')
SERVICE = 'com.javafancn.vpn-navigator.helper'


def run(args, ok=True, timeout=120):
    command = [str(x) for x in args]
    if '/usr/sbin/installer' in command:
        command.insert(command.index('/usr/sbin/installer') + 1, '-dumplog')
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if ok and result.returncode:
        raise AssertionError('Fixture command failed: ' + str(args[0]) + '\n' + result.stdout + result.stderr)
    return result


def health(expected=True):
    result = run([APP / 'Contents/MacOS/VPNNavigatorApp', '--vpnnav-local-health-check'], ok=False)
    assert (result.returncode == 0) == expected, 'Local app trust result did not match expected state\n' + result.stdout + result.stderr


def main():
    assert sys.platform == 'darwin' and os.getuid() != 0
    assert BASE.exists() and APP.exists()
    folder = pathlib.Path(tempfile.mkdtemp(prefix='vpnnav-local-fixture-', dir='/tmp'))
    try:
        health()
        pressure = run(['sudo', 'env', 'GITHUB_ACTIONS=true', PAYLOAD / 'VPNNavigatorHelper', '--self-test-route-pressure'], timeout=240)
        print(pressure.stdout, end='')
        from quit_fixture import exercise_quit
        exercise_quit(run)
        exercise_quit(run)
        evidence = pathlib.Path('/var/run/vpn-navigator/routes.journal')
        assert run(['sudo', 'test', '-e', evidence], ok=False).returncode != 0
        run(['sudo', 'mkdir', '-p', evidence.parent])
        pending = folder / 'recoverable-route.jsonl'
        pending.write_text(json.dumps({'phase': 'begun', 'mutation': {
            'id': str(uuid.uuid4()), 'action': 'add',
            'route': {'prefix': {'network': int(ipaddress.IPv4Address('198.51.100.253')), 'prefix': 32},
                      'destination': {'viaGateway': {'_0': '192.0.2.1'}}}}}) + '\n')
        pending.chmod(0o600)
        run(['sudo', 'cp', pending, evidence])
        exercise_quit(run, recovering=True)
        assert run(['sudo', 'test', '-e', evidence], ok=False).returncode != 0
        malformed = folder / 'malformed-recovery.jsonl'
        malformed.write_text('{ malformed recovery fixture')
        malformed.chmod(0o600)
        run(['sudo', 'cp', malformed, evidence])
        try:
            run([APP / 'Contents/MacOS/VPNNavigatorApp', '--vpnnav-local-quit-rejection-check'])
            assert run(['sudo', 'test', '-e', evidence], ok=False).returncode == 0
        finally:
            run(['sudo', 'rm', evidence])
        manifest = BASE / 'manifest.json'
        saved_manifest = folder / 'manifest-backup.json'
        run(['cp', manifest, saved_manifest])
        run(['sudo', 'python3', '-c', 'import json;from pathlib import Path;p=Path("/Library/Application Support/VPNNavigator/Local/manifest.json");s=json.loads(p.read_text());s["ownerUID"]+=1;p.write_text(json.dumps(s))'])
        health(False)
        run(['sudo', 'cp', saved_manifest, manifest])
        run(['sudo', 'mv', manifest, BASE / 'manifest-held.json'])
        health(False)
        run(['sudo', 'ln', '-s', BASE / 'manifest-held.json', manifest])
        health(False)
        run(['sudo', 'rm', manifest])
        run(['sudo', 'mv', BASE / 'manifest-held.json', manifest])
        health()
        print('PASS: wrong approved user, missing approval and symlink approval rejected.')
        source = folder / 'unapproved.swift'
        source.write_text('''import Foundation
@objc protocol Probe { func health(reply: @escaping (String) -> Void) }
let c = NSXPCConnection(machServiceName: "com.javafancn.vpn-navigator.helper", options: .privileged)
c.remoteObjectInterface = NSXPCInterface(with: Probe.self)
c.invalidationHandler = { exit(0) }; c.interruptionHandler = { exit(0) }; c.resume()
DispatchQueue.global().asyncAfter(deadline: .now() + 4) { exit(0) }
let p = c.remoteObjectProxyWithErrorHandler { _ in exit(0) } as! Probe
p.health { value in exit(value.hasPrefix("VPN Navigator Helper") ? 1 : 0) }
RunLoop.current.run()
''')
        run(['swiftc', source, '-o', folder / 'unapproved'])
        run(['codesign', '--force', '--options', 'runtime', '--sign', '-', '--identifier', 'com.javafancn.vpn-navigator', folder / 'unapproved'])
        run([folder / 'unapproved'])
        print('PASS: different code hash rejected even with the same bundle identifier.')
        # Simulate a prior administrator-approved client identity, then revoke
        # it by restoring the current build approval. This probe deliberately
        # bypasses the app's self-check, so rejection must come from server XPC.
        signature = run(['codesign', '-dv', '--verbose=4', folder / 'unapproved'])
        cdhash = next(line.split('=', 1)[1] for line in signature.stderr.splitlines() if line.startswith('CDHash='))
        prior = json.loads(saved_manifest.read_text())
        prior['binaries']['app']['cdhash'] = cdhash
        prior['binaries']['app']['sha256'] = hashlib.sha256((folder / 'unapproved').read_bytes()).hexdigest()
        prior_manifest = folder / 'prior-approval.json'
        prior_manifest.write_text(json.dumps(prior))
        run(['sudo', 'cp', prior_manifest, manifest])
        try:
            assert run([folder / 'unapproved'], ok=False).returncode == 1, 'Previously approved identity was not accepted'
        finally:
            run(['sudo', 'cp', saved_manifest, manifest])
        run([folder / 'unapproved'])
        health()
        print('PASS: previously approved client hash cannot replay after approval changes.')
        backup = folder / 'engine-backup'
        run(['cp', PAYLOAD / 'openvpn', backup])
        run(['sudo', 'chmod', 'o+w', PAYLOAD / 'openvpn'])
        health(False)
        run(['sudo', 'chmod', 'o-w', PAYLOAD / 'openvpn'])
        run(['sudo', 'python3', '-c', 'from pathlib import Path;p=Path("/Library/Application Support/VPNNavigator/Local/Payload/openvpn");s=bytearray(p.read_bytes());s[-1]^=1;p.write_bytes(s)'])
        health(False)
        run(['sudo', 'cp', backup, PAYLOAD / 'openvpn'])
        run(['sudo', 'chmod', '755', PAYLOAD / 'openvpn'])
        health()
        print('PASS: unsafe permissions and modified engine rejected, then repaired.')
        # A different root service with the same Mach name must not impersonate
        # the installed helper. No credentials are ever used by this fixture.
        fake = folder / 'fake.swift'
        fake.write_text('''import Foundation
@objc protocol Probe { func health(reply: @escaping (String) -> Void) }
class Service: NSObject, Probe { func health(reply: @escaping (String) -> Void) { reply("VPN Navigator Helper (impostor)") } }
class Delegate: NSObject, NSXPCListenerDelegate {
 let service = Service()
 func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
 c.exportedInterface = NSXPCInterface(with: Probe.self); c.exportedObject = service; c.resume(); return true
 }
}
let listener = NSXPCListener(machServiceName: "com.javafancn.vpn-navigator.helper")
let delegate = Delegate(); listener.delegate = delegate; listener.resume(); RunLoop.current.run()
''')
        run(['swiftc', fake, '-o', folder / 'fake'])
        run(['codesign', '--force', '--options', 'runtime', '--sign', '-', folder / 'fake'])
        fake_label = 'com.javafancn.vpn-navigator.local-fixture'
        fake_plist = folder / 'fake.plist'
        fake_plist.write_bytes(plistlib.dumps({'Label': fake_label, 'ProgramArguments': [str(folder / 'fake')], 'MachServices': {SERVICE: True}}))
        run(['sudo', 'chown', '-R', 'root:wheel', folder])
        run(['sudo', 'chmod', '755', folder])
        run(['sudo', 'launchctl', 'bootout', 'system/' + LABEL])
        try:
            run(['sudo', 'launchctl', 'bootstrap', 'system', fake_plist])
            health(False)
        finally:
            run(['sudo', 'launchctl', 'bootout', 'system/' + fake_label], ok=False)
            run(['sudo', 'launchctl', 'bootstrap', 'system', PLIST])
        health()
        print('PASS: impostor root service rejected by app, approved helper restored.')
        # Maintenance is authenticated XPC, not a root shell from the app.
        # User jobs must be installed/loaded, then fully removed before root
        # approval is retired. A retired approval cannot authorize XPC.
        health()
        run([APP / 'Contents/MacOS/VPNNavigatorApp', '--vpnnav-local-services-self-test'])
        assert not (BASE / 'manifest.json').exists() and (BASE / 'retired-approval.json').exists()
        assert run(['launchctl', 'print', 'system/' + LABEL], ok=False).returncode != 0
        health(False)
        print('PASS: per-user rules/login services and authenticated root retirement.')
        # A journal created by this fixture must block both update and uninstall.
        # Never delete unknown recovery evidence, even on a CI runner.
        journal = pathlib.Path('/var/run/vpn-navigator/routes.journal')
        assert run(['sudo', '/bin/test', '-e', journal], ok=False).returncode != 0
        run(['sudo', 'mkdir', '-p', journal.parent])
        run(['sudo', 'touch', journal])
        installer = next(pathlib.Path('dist').glob('*-Local.pkg'))
        uninstaller = next(pathlib.Path('dist').glob('*-Local-Uninstall.pkg'))
        try:
            assert run(['sudo', '/usr/sbin/installer', '-pkg', installer, '-target', '/'], ok=False).returncode != 0
            assert run(['sudo', '/usr/sbin/installer', '-pkg', uninstaller, '-target', '/'], ok=False).returncode != 0
            assert BASE.exists(), 'Rejected update removed protected payload'
            assert APP.exists(), 'Rejected update removed installed app'
            assert run(['sudo', '/bin/test', '-e', journal], ok=False).returncode == 0, 'Recovery evidence was removed'
        finally:
            run(['sudo', 'rm', journal])
        print('PASS: unresolved recovery blocks update/uninstall and preserves evidence.')
        run(['sudo', 'chmod', 'g+w', PAYLOAD])
        try:
            assert run(['sudo', '/usr/sbin/installer', '-pkg', installer, '-target', '/'], ok=False).returncode != 0
            assert run(['sudo', '/usr/sbin/installer', '-pkg', uninstaller, '-target', '/'], ok=False).returncode != 0
        finally:
            run(['sudo', 'chmod', 'g-w', PAYLOAD])
        setup_backup = folder / 'setup-backup'
        run(['sudo', 'cp', PAYLOAD / 'VPNNavigatorLocalSetup', setup_backup])
        run(['sudo', 'python3', '-c', 'from pathlib import Path;p=Path("/Library/Application Support/VPNNavigator/Local/Payload/VPNNavigatorLocalSetup");s=bytearray(p.read_bytes());s[-1]^=1;p.write_bytes(s)'])
        try:
            assert run(['sudo', '/usr/sbin/installer', '-pkg', uninstaller, '-target', '/'], ok=False).returncode != 0
            assert BASE.exists() and APP.exists()
        finally:
            run(['sudo', 'cp', setup_backup, PAYLOAD / 'VPNNavigatorLocalSetup'])
            run(['sudo', 'chmod', '755', PAYLOAD / 'VPNNavigatorLocalSetup'])
        print('PASS: installer guards reject writable payload and altered setup before execution.')
        # Incomplete protected payload remains untrusted and is repaired only by
        # reinstalling a trusted PKG with administrator authorization.
        run(['sudo', 'rm', PAYLOAD / 'macos-dns-updown.sh'])
        health(False)
        run(['sudo', '/usr/sbin/installer', '-pkg', installer, '-target', '/'])
        health()
        print('PASS: administrator-approved reinstall repairs incomplete payload after maintenance.')
        run([APP / 'Contents/MacOS/VPNNavigatorApp', '--vpnnav-local-services-self-test'])
        run(['sudo', '/usr/sbin/installer', '-pkg', PAYLOAD / 'VPNNavigator-Uninstall.pkg', '-target', '/'])
        assert not BASE.exists() and not PLIST.exists() and not APP.exists()
        assert run(['launchctl', 'print', 'system/' + LABEL], ok=False).returncode != 0
        print('PASS: actual local install, bidirectional XPC trust and complete system uninstall.')
        # Absence of the setup tool alone is not proof of a complete uninstall.
        run(['sudo', 'touch', PLIST])
        try:
            assert run(['sudo', '/usr/sbin/installer', '-pkg', uninstaller, '-target', '/'], ok=False).returncode != 0
            assert PLIST.exists(), 'Incomplete-uninstall evidence was removed'
        finally:
            run(['sudo', 'rm', PLIST])
        run(['sudo', '/usr/sbin/installer', '-pkg', uninstaller, '-target', '/'])
        print('PASS: missing setup with residual service requires repair; already-removed system uninstall is idempotent.')
    finally:
        run(['sudo', 'launchctl', 'bootout', 'system/' + LABEL], ok=False)
        run(['sudo', 'launchctl', 'bootout', 'system/com.javafancn.vpn-navigator.local-fixture'], ok=False)
        run(['sudo', 'rm', '-rf', folder])


if __name__ == '__main__':
    main()
