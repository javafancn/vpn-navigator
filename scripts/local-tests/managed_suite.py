"""Real installed app -> XPC -> TLS -> kernel routes, on disposable Macs only."""
import ipaddress
import json
import os
import re
import socket
import threading
import time
import uuid
from pathlib import Path
from managed_transport import ENDPOINT, transport
from quit_fixture import exercise_quit

APP = Path('/Applications/VPN Navigator.app/Contents/MacOS/VPNNavigatorApp')
MANIFEST = Path('/Library/Application Support/VPNNavigator/Local/manifest.json')


def control_exceptions(run):
    # Keep the CI controller reachable while REAL /1 VPN routes are installed.
    # These are ordinary explicit direct rules, supplied through the real UI
    # model. No production endpoint/path validation or route executor is mocked.
    default = run(['/sbin/route', '-n', 'get', 'default']).stdout
    gateway = re.search(r'^\s*gateway:\s*(\S+)', default, re.M)[1]
    interface = re.search(r'^\s*interface:\s*(\S+)', default, re.M)[1]
    peers = run(['sudo', '-n', '/usr/sbin/lsof', '-nP', '-iTCP', '-sTCP:ESTABLISHED', '-Fn'], ok=False).stdout
    networks = set()
    for address in re.findall(r'->([0-9.]+):[0-9]+', peers):
        ip = ipaddress.IPv4Address(address)
        if ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip in ipaddress.ip_network('100.64.0.0/10'):
            continue
        path = run(['/sbin/route', '-n', 'get', address]).stdout
        fields = dict(re.findall(r'^\s*(gateway|interface):\s*(\S+)', path, re.M))
        if fields.get('gateway') == gateway and fields.get('interface') == interface:
            networks.add(str(ipaddress.ip_network(address + '/24', strict=False)))
    assert networks and len(networks) <= 100, 'CI controller direct exceptions missing or excessive'
    return [{'id': str(uuid.uuid4()), 'cidr': value, 'action': 'direct', 'enabled': True} for value in sorted(networks)]


def tunnel_interfaces(run):
    found, current = {}, None
    for line in run(['/sbin/ifconfig', '-a']).stdout.splitlines():
        if line and not line[0].isspace():
            current = line.split(':', 1)[0]
        for address in ['198.18.254.1', '198.18.254.2']:
            if line.split()[:2] == ['inet', address]:
                assert current.startswith('utun') and current[4:].isdigit()
                found[address] = current
    assert len(found) == 2 and len(set(found.values())) == 2
    return found['198.18.254.1'], found['198.18.254.2']


def data_echo(run, probe, server_tunnel, client_tunnel, aliases):
    # Interface-scoped link-local sources avoid Darwin's same-host LOCAL/lo0
    # shortcut. Both directions must traverse the actual OpenVPN data stream.
    with aliases([('fe80::1', server_tunnel), ('fe80::2', client_tunnel)]):
        bound = getattr(socket, 'IPV6_BOUND_IF', 125)
        ss, cs = socket.if_nametoindex(server_tunnel), socket.if_nametoindex(client_tunnel)
        errors = []
        with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as echo, socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sender:
            for sock, scope, address in [(echo, ss, 'fe80::1'), (sender, cs, 'fe80::2')]:
                sock.setsockopt(socket.IPPROTO_IPV6, bound, scope)
                sock.bind((address, 0, 0, scope)); sock.settimeout(6)
            def respond():
                try:
                    for _ in range(3):
                        packet, peer = echo.recvfrom(2048); echo.sendto(packet, peer)
                except OSError as error:
                    errors.append(type(error).__name__)
            thread = threading.Thread(target=respond, daemon=True)
            thread.start()
            time.sleep(1.1)
            before = json.loads(run([probe, '--traffic']).stdout)
            try:
                for number in range(3):
                    packet = bytes([number]) + os.urandom(1199)
                    sender.sendto(packet, ('fe80::1', echo.getsockname()[1], 0, cs))
                    assert sender.recvfrom(2048)[0] == packet
            finally:
                thread.join(timeout=7)
            assert not errors and not thread.is_alive(), 'Encrypted managed data responder failed'
        for _ in range(30):
            after = json.loads(run([probe, '--traffic']).stdout)
            if all(after[key] - before[key] >= 3000 for key in ['sent', 'received']):
                return
            time.sleep(.2)
        raise AssertionError('Managed payload did not traverse both encrypted data directions')


def exercise_managed(run, folder, probe, config, profile, port, start_server, stop_server,
                     app_approval, probe_approval, openssl, aliases):
    original = config.read_text()
    before_default = run(['/sbin/route', '-n', 'get', 'default']).stdout
    rules = folder / 'managed-rules.txt'
    # Deliberately non-adjacent /32s: custom-direct merging must not collapse
    # this into a handful of routes. Exceeds the reported failure at ~2,542.
    rules.write_text(''.join(f'11.65.{i // 128}.{(i % 128) * 2}/32\n' for i in range(4096)))
    extra = folder / 'managed-server.ext'
    extra.write_text('extendedKeyUsage=serverAuth\n')
    run(['env', 'OPENSSL_CONF=/dev/null', openssl, 'req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
         '-subj', '/CN=vpnnav-ci-server', '-keyout', folder / 'managed-server.key', '-out', folder / 'managed-server.csr'])
    run(['env', 'OPENSSL_CONF=/dev/null', openssl, 'x509', '-req', '-in', folder / 'managed-server.csr', '-CA', folder / 'ca.crt',
         '-CAkey', folder / 'ca.key', '-CAcreateserial', '-days', '1', '-extfile', extra, '-out', folder / 'managed-server.crt'])
    exceptions = control_exceptions(run)
    stop_server()
    try:
        for protocol in ['tcp', 'udp']:
            server = '\n'.join(line for line in original.splitlines() if not line.startswith('server-ipv6 ')) + '\n'
            server = server.replace('proto tcp4-server', 'proto ' + ('tcp4-server' if protocol == 'tcp' else 'udp4'))
            server = server.replace(f'cert {folder}/server.crt', f'cert {folder}/managed-server.crt')
            server = server.replace(f'key {folder}/server.key', f'key {folder}/managed-server.key')
            server += 'tls-version-max 1.2\n'
            config.write_text(server)
            start_server()
            client = profile.replace('# VPNNAV_EXPECT_DUAL_STACK\n', '').replace('proto tcp-client', 'proto ' + ('tcp-client' if protocol == 'tcp' else 'udp'))
            client = client.replace('remote 127.0.0.1 ', 'remote ' + ENDPOINT + ' ')
            client += 'auth SHA256\ncipher AES-128-GCM\ntls-client\ntls-cipher TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256\n'
            if protocol == 'udp':
                client += 'explicit-exit-notify 1\n'
            profile_path = folder / ('managed-' + protocol + '.ovpn')
            profile_path.write_text(client); profile_path.chmod(0o600)
            with transport(run, folder, port, protocol):
                for mode in ['Original', 'Full VPN', 'China Direct']:
                    case = folder / 'managed-case.json'
                    report_path = folder / 'managed-report.json'
                    case.write_text(json.dumps({'profilePath': str(profile_path), 'rulesPath': str(rules),
                        'reportPath': str(report_path), 'mode': mode, 'customRules': exceptions,
                        'switchRoundTrip': mode == 'Full VPN'})); case.chmod(0o600)
                    run(['sudo', '-n', 'cp', app_approval, MANIFEST])
                    try:
                        result = run([APP, '--vpnnav-local-managed-connect', case], timeout=300)
                        print(result.stdout, end='', flush=True)
                        report = json.loads(report_path.read_text())
                        assert report['state'] == 'connected' and report['routingMode'] == mode
                        server_tunnel, client_tunnel = tunnel_interfaces(run)
                        if mode != 'Original':
                            for target, expected in [('8.8.8.8', client_tunnel),
                                ('11.65.0.0', client_tunnel if mode == 'Full VPN' else None)]:
                                observed = run(['/sbin/route', '-n', 'get', target]).stdout
                                interface = re.search(r'^\s*interface:\s*(\S+)', observed, re.M)[1]
                                assert interface == expected if expected else re.fullmatch(r'en[0-9]+', interface)
                            journal = run(['sudo', '-n', 'cat', '/var/run/vpn-navigator/routes.journal']).stdout
                            if mode == 'China Direct':
                                assert journal.count('"committed"') >= 4096, 'Large rule plan was not actually installed'
                        run(['sudo', '-n', 'cp', probe_approval, MANIFEST])
                        data_echo(run, probe, server_tunnel, client_tunnel, aliases)
                        run(['sudo', '-n', 'cp', app_approval, MANIFEST])
                        exercise_quit(run, cleanup_timeout=240)
                        print('PASS: ' + protocol.upper() + ' / ' + mode + ': real application connect, kernel route selection, bidirectional encrypted payload, watchdog stability and actual Quit cleanup.', flush=True)
                    finally:
                        run(['sudo', '-n', 'cp', probe_approval, MANIFEST])
                        run([probe, '--disconnect'], ok=False, timeout=240)
            stop_server()
        after = run(['/sbin/route', '-n', 'get', 'default']).stdout
        fields = lambda text: dict(re.findall(r'^\s*(gateway|interface):\s*(\S+)', text, re.M))
        assert fields(after) == fields(before_default), 'Managed test did not restore the physical default'
        print('PASS: six real TCP/UDP mode combinations and live switch round trips; physical default restored.', flush=True)
    finally:
        stop_server()
        config.write_text(original)
        run(['sudo', '-n', 'cp', probe_approval, MANIFEST])
        start_server()
