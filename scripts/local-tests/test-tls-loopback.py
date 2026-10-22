#!/usr/bin/env python3
"""Disposable macOS runner only: real TLS/utun; no default routes or DNS pushes."""
import hashlib
import contextlib
import ipaddress
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from auth_suite import exercise_auth

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


@contextlib.contextmanager
def scoped_fixture_routes(pairs):
    """Fixed fixture ULA /128 routes only, scoped to the two owned test utuns.

    Keep the kernel's unscoped local-address routes intact. Verify exact scoped
    ownership before deletion; failed/ambiguous mutations fail the disposable
    job rather than deleting a pre-existing route. Never changes a default.
    """
    installed = []
    def inspect(target, interface):
        return run(['/sbin/route', '-n', 'get', '-inet6', '-ifscope', interface, '-host', target], ok=False)
    def owned(observed, target, interface):
        fields = dict(line.strip().split(':', 1) for line in observed.stdout.splitlines() if ':' in line)
        destination = fields.get('destination', '').strip().split('%')[0]
        return observed.returncode == 0 and destination and ipaddress.IPv6Address(destination) == ipaddress.IPv6Address(target) and fields.get('interface', '').strip() == interface and 'IFSCOPE' in fields.get('flags', '')
    try:
        for target, interface in pairs:
            assert sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
            assert ipaddress.IPv6Address(target) in ipaddress.IPv6Network('fd42:766e:6176:1::/64')
            assert interface.startswith('utun') and interface[4:].isdigit()
            before = inspect(target, interface)
            assert not owned(before, target, interface), 'Scoped fixture route already exists; refusing to replace it: ' + before.stdout
            run(['sudo', '-n', '/sbin/route', '-n', 'add', '-inet6', '-ifscope', interface, '-host', target, '-interface', interface])
            installed.append((target, interface))
            observed = inspect(target, interface)
            assert owned(observed, target, interface), 'Scoped fixture route was not observed exactly: ' + observed.stdout
        yield
    finally:
        for target, interface in reversed(installed):
            observed = inspect(target, interface)
            assert owned(observed, target, interface), 'Scoped fixture ownership lost; retaining the route'
            run(['sudo', '-n', '/sbin/route', '-n', 'delete', '-inet6', '-ifscope', interface, '-host', target])
            assert not owned(inspect(target, interface), target, interface), 'Scoped fixture route was not removed'


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
    transport_host = "127.0.0.1"
    before6 = run(["/usr/sbin/netstat", "-rn", "-f", "inet6"]).stdout
    defaults6 = lambda text: [line.split() for line in text.splitlines() if line.split()[:1] == ["default"]]
    def stop_server():
        nonlocal server, log
        if server is not None and server.poll() is None:
            # Own live Popen group; never signal a PID recovered from a journal.
            run(['sudo', '/bin/kill', '-TERM', '--', '-' + str(server.pid)], ok=False)
            try:
                server.wait(timeout=8)
            except subprocess.TimeoutExpired:
                run(['sudo', '/bin/kill', '-KILL', '--', '-' + str(server.pid)], ok=False)
                server.wait(timeout=5)
        if log:
            log.close()
            log = None

    def start_server():
        nonlocal server, log
        log = (folder / 'server.log').open('a')
        server = subprocess.Popen(['sudo', '-n', str(ENGINE), '--config', str(config)], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(60):
            assert server.poll() is None, 'TLS fixture server exited'
            try:
                with socket.create_connection((transport_host, port), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.1)
        raise AssertionError('TLS fixture did not start')
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
server-ipv6 fd42:766e:6176:1::/64
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
        profile = f"""# VPNNAV_EXPECT_DUAL_STACK
client
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
        start_server()
        result = run([probe, valid, invalid], ok=False, timeout=120)
        print(result.stdout, end='')
        assert result.returncode == 0, 'Installed helper TLS fixture failed: ' + result.stderr
        # Exercise actual IPv6 data and the journal executor without changing defaults.
        run([probe, '--connect-only', valid])
        # Both ends run on one host. Bind BOTH UDP sockets to their respective
        # utuns: a kernel-generated ICMP reply can otherwise take a local route
        # to the client's address and never return through the encrypted stream.
        interface_addresses = {}
        current_tunnel = None
        for line in run(['/sbin/ifconfig', '-a']).stdout.splitlines():
            if line and not line[0].isspace():
                current_tunnel = line.split(':', 1)[0]
                interface_addresses[current_tunnel] = []
            if current_tunnel and line.split()[:1] == ['inet6']:
                interface_addresses[current_tunnel].append(line.split()[1].split('%')[0])
            if 'inet 198.18.254.2 ' in line:
                client_tunnel = current_tunnel
        assert 'client_tunnel' in locals(), 'Client fixture utun not found'
        assert client_tunnel.startswith('utun') and client_tunnel[4:].isdigit()
        client6 = next(address for address in interface_addresses[client_tunnel] if address.startswith('fd42:766e:6176:1:'))
        server6 = 'fd42:766e:6176:1::1'
        server_tunnel = next(name for name, addresses in interface_addresses.items() if server6 in addresses)
        assert server_tunnel != client_tunnel and server_tunnel.startswith('utun') and server_tunnel[4:].isdigit()
        # Darwin bsd/netinet6/in6.h defines IPV6_BOUND_IF as 125; some Python
        # builds do not export the constant. Never binds a physical interface.
        bound_if = getattr(socket, 'IPV6_BOUND_IF', 125)
        # Bound sockets still see local /128 routes on a same-host fixture.
        # Add more specific scoped /128 entries for BOTH directions without
        # replacing the unscoped routes that belong to the server/client.
        with scoped_fixture_routes([(server6, client_tunnel), (client6, server_tunnel)]):
            echo_errors = []
            with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as echo, socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sender:
                echo.setsockopt(socket.IPPROTO_IPV6, bound_if, socket.if_nametoindex(server_tunnel))
                sender.setsockopt(socket.IPPROTO_IPV6, bound_if, socket.if_nametoindex(client_tunnel))
                echo.bind((server6, 0)); sender.bind((client6, 0))
                echo.settimeout(5); sender.settimeout(5)
                def echo_packets():
                    try:
                        for _ in range(3):
                            packet, peer = echo.recvfrom(2048)
                            echo.sendto(packet, peer)
                    except OSError as error:
                        echo_errors.append(type(error).__name__)
                echo_thread = threading.Thread(target=echo_packets, daemon=True)
                echo_thread.start()
                time.sleep(1.2)  # Let the first management byte-count receipt settle.
                before_data = json.loads(run([probe, '--traffic']).stdout)
                try:
                    for number in range(3):
                        packet = bytes([number]) + os.urandom(1199)
                        sender.sendto(packet, echo.getsockname())
                        reply, _ = sender.recvfrom(2048)
                        assert reply == packet, 'IPv6 UDP echo payload changed'
                finally:
                    echo_thread.join(timeout=6)
                assert not echo_errors and not echo_thread.is_alive(), 'Bound IPv6 UDP responder did not finish: ' + str(echo_errors)
            for _ in range(30):
                after_data = json.loads(run([probe, '--traffic']).stdout)
                if all(after_data[key] - before_data[key] >= 3000 for key in ['sent', 'received']):
                    break
                time.sleep(0.2)
            else:
                raise AssertionError('IPv6 UDP echo did not traverse both encrypted data directions: ' + str(before_data) + ' -> ' + str(after_data))
        current_tunnel = client_tunnel
        kernel = run(['sudo', '-n', 'env', 'GITHUB_ACTIONS=true', PAYLOAD / 'VPNNavigatorHelper', '--self-test-ipv6-kernel', current_tunnel])
        print(kernel.stdout, end='')
        run([probe, '--disconnect'])
        print('PASS: real IPv6 UDP echo traffic passes through both encrypted TLS/utun data directions.')
        log.flush()
        assert 'unknown ca' in (folder / 'server.log').read_text().lower(), 'TLS server did not observe the controlled wrong-CA rejection'
        # IPv6 transport and IPv6-only payload negotiate through the installed helper too.
        saved_config, saved_port = config.read_text(), port
        stop_server()
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as reservation6:
            reservation6.bind(('::1', 0)); port = reservation6.getsockname()[1]
        transport_host = '::1'
        config6 = saved_config.replace('proto tcp4-server', 'proto tcp6-server').replace('local 127.0.0.1', 'local ::1').replace(f'port {saved_port}\n', f'port {port}\n')
        config.write_text(config6)
        text6 = profile.replace('proto tcp-client', 'proto tcp6-client').replace(f'remote 127.0.0.1 {saved_port}', f'remote ::1 {port}')
        valid6, invalid6 = folder / 'ipv6-transport.ovpn', folder / 'ipv6-transport-wrong.ovpn'
        valid6.write_text(text6); invalid6.write_text(text6.replace((folder / 'ca.crt').read_text(), (folder / 'wrong-ca.crt').read_text()))
        valid6.chmod(0o600); invalid6.chmod(0o600)
        start_server()
        observed6 = run([probe, valid6, invalid6], timeout=120); print(observed6.stdout, end='')
        print('PASS: IPv6 TCP transport negotiates a dual-stack tunnel through the installed helper.')
        stop_server()
        config.write_text(config6.replace('server 198.18.254.0 255.255.255.0', 'mode server\ntls-server'))
        only6 = text6.replace('VPNNAV_EXPECT_DUAL_STACK', 'VPNNAV_EXPECT_IPV6_ONLY')
        valid6.write_text(only6); invalid6.write_text(only6.replace((folder / 'ca.crt').read_text(), (folder / 'wrong-ca.crt').read_text()))
        start_server()
        observed6 = run([probe, valid6, invalid6], timeout=120); print(observed6.stdout, end='')
        print('PASS: IPv6-only tunnel addresses are confirmed and DNS ownership is restored without an IPv4 tunnel address.')
        stop_server(); config.write_text(saved_config); port = saved_port; transport_host = '127.0.0.1'; start_server()
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
        exercise_auth(folder, profile, ssl, probe, run, start_server, stop_server, config)
        for name in ['active.ovpn', 'routes.journal', 'dns.journal', 'pf-guard.json', 'openvpn-child.json']:
            assert run(['sudo', '/bin/test', '-e', '/var/run/vpn-navigator/' + name], ok=False).returncode != 0, 'Unresolved owned session: ' + name
        assert defaults6(run(['/usr/sbin/netstat', '-rn', '-f', 'inet6']).stdout) == defaults6(before6), 'IPv6 fixture changed a default route'
        assert default_path() == before_route, 'Loopback TLS fixture changed the default network path'
    finally:
        if approved:
            run([folder / 'TLSProbe', '--disconnect'], ok=False)
            saved = folder / 'original-approval.json'
            saved.write_bytes(original)
            run(['sudo', 'cp', saved, MANIFEST])
        stop_server()
        if sys.exc_info()[0] is not None:
            server_log = folder / 'server.log'
            if server_log.exists():
                diagnostic = server_log.read_text()
                redactions = folder / 'redactions.json'
                if redactions.exists():
                    for secret in json.loads(redactions.read_text()):
                        if secret:
                            diagnostic = diagnostic.replace(secret, '[redacted fixture value]')
                print('Synthetic TLS fixture log:\n' + diagnostic[-5000:])
        run(['sudo', 'rm', '-rf', folder])


if __name__ == '__main__':
    main()
