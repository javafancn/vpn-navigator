#!/usr/bin/env python3
"""Disposable macOS runner only: real TLS/utun; no default routes or DNS pushes."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

BASE = Path('/Library/Application Support/VPNNavigator/Local')
PAYLOAD = BASE / 'Payload'
MANIFEST = BASE / 'manifest.json'
ENGINE = PAYLOAD / 'openvpn'


def run(arguments, ok=True, timeout=90):
    value = subprocess.run([str(x) for x in arguments], capture_output=True, text=True, timeout=timeout)
    if ok and value.returncode:
        raise AssertionError('TLS fixture command failed: ' + str(arguments[0]) + '\n' + value.stdout + value.stderr)
    return value


def default_path():
    route = run(['/sbin/route', '-n', 'get', 'default']).stdout
    return tuple(line.strip() for line in route.splitlines() if line.strip().startswith(('gateway:', 'interface:')))


def main():
    assert sys.platform == 'darwin' and os.getuid() != 0
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Disposable GitHub macOS runners only'
    assert BASE.exists() and MANIFEST.exists()
    openssl = Path(os.environ['RUNNER_TEMP']) / 'engine-prefix/bin/openssl'
    assert openssl.is_file()
    original = MANIFEST.read_bytes()
    folder = Path(tempfile.mkdtemp(prefix='vpnnav-tls-fixture-', dir='/tmp'))
    folder.chmod(0o700)
    server = None
    log = None
    approved = False
    before_route = default_path()
    try:
        def ssl(*args):
            if args[0] == 'req':
                args = (args[0], '-config', '/dev/null', *args[1:])
            return run([openssl, *args])

        ssl('req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1', '-subj', '/CN=VPNNav CI CA',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
            '-keyout', folder / 'ca.key', '-out', folder / 'ca.crt')
        ssl('req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1', '-subj', '/CN=VPNNav CI Wrong CA',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-keyout', folder / 'wrong-ca.key', '-out', folder / 'wrong-ca.crt')
        for name, purpose in [('server', 'serverAuth'), ('client', 'clientAuth')]:
            ssl('req', '-new', '-newkey', 'rsa:2048', '-noenc', '-subj', '/CN=vpnnav-ci-' + name,
                '-keyout', folder / (name + '.key'), '-out', folder / (name + '.csr'))
            extension = folder / (name + '.ext')
            extension.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=' + purpose + '\n')
            ssl('x509', '-req', '-in', folder / (name + '.csr'), '-CA', folder / 'ca.crt', '-CAkey', folder / 'ca.key',
                '-CAcreateserial', '-days', '1', '-extfile', extension, '-out', folder / (name + '.crt'))
        for key in folder.glob('*.key'):
            key.chmod(0o600)
        with socket.socket() as port_reservation:
            port_reservation.bind(('127.0.0.1', 0))
            port = port_reservation.getsockname()[1]
        config = folder / 'server.conf'
        config.write_text(f"""dev tun
dev-node utun
proto tcp4-server
local 127.0.0.1
port {port}
topology subnet
server 198.18.254.0 255.255.255.0
ca {folder}/ca.crt
cert {folder}/server.crt
key {folder}/server.key
dh none
remote-cert-tls client
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
script-security 1
verb 3
""")
        profile = f"""client
dev tun
proto tcp-client
remote 127.0.0.1 {port}
nobind
remote-cert-tls server
verify-x509-name vpnnav-ci-server name
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
connect-retry 1 1
verb 3
"""
        for tag in ['ca', 'cert', 'key']:
            resource = 'ca.crt' if tag == 'ca' else 'client.' + ('crt' if tag == 'cert' else 'key')
            profile += '<' + tag + '>\n' + (folder / resource).read_text() + '</' + tag + '>\n'
        valid = folder / 'valid.ovpn'
        invalid = folder / 'wrong-ca.ovpn'
        valid.write_text(profile)
        invalid.write_text(profile.replace((folder / 'ca.crt').read_text(), (folder / 'wrong-ca.crt').read_text()))
        valid.chmod(0o600)
        invalid.chmod(0o600)
        probe = folder / 'TLSProbe'
        run(['swiftc', '-swift-version', '5', 'scripts/local-tests/TLSProbe.swift', '-o', probe])
        run(['codesign', '--force', '--options', 'runtime', '--sign', '-', '--identifier', 'com.javafancn.vpn-navigator', probe])
        signature = run(['codesign', '-dv', '--verbose=4', probe])
        cdhash = next(line.split('=', 1)[1] for line in signature.stderr.splitlines() if line.startswith('CDHash='))
        approval = json.loads(original)
        approval['binaries']['app']['cdhash'] = cdhash
        approval['binaries']['app']['sha256'] = hashlib.sha256(probe.read_bytes()).hexdigest()
        temporary = folder / 'approval.json'
        temporary.write_text(json.dumps(approval))
        run(['sudo', 'cp', temporary, MANIFEST])
        approved = True
        log = (folder / 'server.log').open('w')
        server = subprocess.Popen(['sudo', '-n', str(ENGINE), '--config', str(config)], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(60):
            assert server.poll() is None, 'TLS fixture server exited'
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise AssertionError('TLS fixture did not start')
        result = run([probe, valid, invalid], ok=False, timeout=120)
        print(result.stdout, end='')
        assert result.returncode == 0, 'Installed helper TLS fixture failed: ' + result.stderr
        log.flush()
        assert 'unknown ca' in (folder / 'server.log').read_text().lower(), 'TLS server did not observe the controlled wrong-CA rejection'
        # Prove parent loss does not leave the privileged VPN engine alive.
        # launchctl addresses the exact daemon job, without a numeric PID kill.
        run([probe, '--connect-only', valid])
        record = json.loads(run(['sudo', 'cat', '/var/run/vpn-navigator/openvpn-child.json']).stdout)
        child_pid = int(record['pid'])
        assert child_pid > 1
        run(['sudo', '/bin/launchctl', 'kill', 'SIGKILL', 'system/com.javafancn.vpn-navigator.local-helper'])
        for _ in range(100):
            if run(['sudo', '/bin/kill', '-0', str(child_pid)], ok=False).returncode != 0:
                break
            time.sleep(0.1)
        else:
            raise AssertionError('Engine outlived its crashed controller')
        # A restarted helper must preserve evidence until explicit typed recovery.
        assert run(['sudo', '/bin/test', '-e', '/var/run/vpn-navigator/active.ovpn'], ok=False).returncode == 0
        for _ in range(4):
            recovery = run([probe, '--recover'], ok=False)
            if recovery.returncode == 0:
                print(recovery.stdout, end='')
                break
            time.sleep(0.5)
        else:
            raise AssertionError('Explicit recovery after controller crash failed: ' + recovery.stdout)
        run([probe, valid, invalid], timeout=120)
        print('PASS: crashed controller closes its child, preserves evidence, recovers and reconnects.')
        for name in ['active.ovpn', 'routes.journal', 'dns.journal', 'pf-guard.json', 'openvpn-child.json']:
            assert run(['sudo', '/bin/test', '-e', '/var/run/vpn-navigator/' + name], ok=False).returncode != 0, 'Unresolved owned session: ' + name
        assert default_path() == before_route, 'Loopback TLS fixture changed the default network path'
    finally:
        if approved:
            run([folder / 'TLSProbe', '--disconnect'], ok=False)
            saved = folder / 'original-approval.json'
            saved.write_bytes(original)
            run(['sudo', 'cp', saved, MANIFEST])
        if server is not None and server.poll() is None:
            # The live Popen session leader prevents its process-group ID from
            # being reused while cleanup targets this exact fixture group.
            run(['sudo', '/bin/kill', '-TERM', '--', '-' + str(server.pid)], ok=False)
            try:
                server.wait(timeout=8)
            except subprocess.TimeoutExpired:
                run(['sudo', '/bin/kill', '-KILL', '--', '-' + str(server.pid)], ok=False)
                server.wait(timeout=5)
        if log:
            log.close()
        if sys.exc_info()[0] is not None:
            server_log = folder / 'server.log'
            if server_log.exists():
                print('Synthetic TLS fixture log:\n' + server_log.read_text()[-5000:])
        run(['sudo', 'rm', '-rf', folder])


if __name__ == '__main__':
    main()
