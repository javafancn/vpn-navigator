"""Real system DNS -> IPv4 HTTP through TLS, without Darwin's LOCAL shortcut.

The isolated server pushes ordinary client-nat and iroute for a non-local source.
Only server-side packets are redirected to disposable DNS/HTTP responders. The
client must select its real VPN routes; curl uses the system resolver unchanged.
"""
import base64
import contextlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import socketserver
import ssl
import struct
import sys
import threading
import time
import uuid

DNS = '1.2.4.8'
WEB = '198.19.100.80'
CLIENT_ALIAS = '198.18.254.99'


class IsolatedHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls getfqdn(0.0.0.0), resolving the runner's
        # unrelated private host name AFTER VPN DNS is installed. That setup
        # lookup can stall for ~35 s and says nothing about client web latency.
        # Bind normally and use a fixed synthetic name; client DNS stays real.
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'vpnnav-fixture'
        self.server_port = self.server_address[1]


def upstream_resolver(run):
    text = run(['/usr/sbin/scutil', '--dns']).stdout
    for ip in re.findall(r'nameserver\[[0-9]+\]\s*:\s*([0-9.]+)', text):
        if ipaddress.IPv4Address(ip).is_loopback:
            continue
        path = run(['/sbin/route', '-n', 'get', ip]).stdout
        iface = re.search(r'^\s*interface:\s*((?:en|bridge)[0-9]+)\s*$', path, re.M)
        if iface:
            return ip, socket.if_nametoindex(iface[1])
    raise AssertionError('No physical CI DNS resolver; cannot preserve runner DNS')


def https_server(folder, handler, address=('0.0.0.0', 0)):
    server = IsolatedHTTPServer(address, handler)
    try:
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(folder / 'web.crt', folder / 'web.key')
        server.socket = tls.wrap_socket(server.socket, server_side=True)
    except BaseException:
        server.server_close()
        raise
    return server


@contextlib.contextmanager
def web_fixture(run, folder, server_tunnel, upstream):
    assert sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
    assert re.fullmatch(r'utun[0-9]+', server_tunnel)
    counts = {'dns': 0, 'http': 0, 'wrong_source': 0}
    class DNSHandler(socketserver.BaseRequestHandler):
        def handle(self):
            packet, udp = self.request
            if self.client_address[0] != CLIENT_ALIAS:
                counts['wrong_source'] += 1
                return
            try:
                end, labels = 12, []
                while packet[end]:
                    size = packet[end]
                    if size > 63 or end + size + 1 >= len(packet):
                        return
                    labels.append(packet[end + 1:end + 1 + size].decode('ascii')); end += size + 1
                end += 1
                kind = struct.unpack('!H', packet[end:end + 2])[0]
                end += 4
                name = '.'.join(labels).lower()
                if name.endswith('.vpnnav.test'):
                    counts['dns'] += 1
                    answer = b''
                    if kind == 1:
                        answer = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4) + socket.inet_aton(WEB)
                    response = packet[:2] + struct.pack('!HHHHH', 0x8180, 1, bool(answer), 0, 0) + packet[12:end] + answer
                else:
                    # Keep the CI controller's DNS working during real /1 routes.
                    # This is the isolated SERVER's upstream, never a client bypass.
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as relay:
                        relay.setsockopt(socket.IPPROTO_IP, getattr(socket, 'IP_BOUND_IF', 25), upstream[1])
                        relay.settimeout(3)
                        relay.sendto(packet, (upstream[0], 53))
                        response = relay.recv(4096)
                udp.sendto(response, self.client_address)
            except (OSError, IndexError, UnicodeError, struct.error):
                return
    class HTTPHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.client_address[0] != CLIENT_ALIAS:
                self.send_error(403); return
            counts['http'] += 1
            body = ('vpnnav-managed-web:' + self.headers.get('Host', '') + ':' + 'x' * 8192).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *args):
            pass
    class UDP(socketserver.ThreadingUDPServer):
        daemon_threads = True
    dns = UDP(('0.0.0.0', 0), DNSHandler)
    http_service = https_server(folder, HTTPHandler)
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in [dns, http_service]]
    anchor = 'com.apple/zzz.vpnnav-data-' + uuid.uuid4().hex
    def pf(*args, ok=True):
        return run(['sudo', '-n', '/sbin/pfctl', *args], ok=ok)
    rules = folder / 'managed-web.pf'
    rules.write_text(
        f'rdr pass on {server_tunnel} inet proto udp from {CLIENT_ALIAS} to {{ {DNS}, 1.1.1.1, 9.9.9.9 }} port 53 -> 198.18.254.1 port {dns.server_address[1]}\n'
        f'rdr pass on {server_tunnel} inet proto tcp from {CLIENT_ALIAS} to {WEB} port 443 -> 198.18.254.1 port {http_service.server_address[1]}\n')
    rules.chmod(0o600)
    owned_route = False
    before = pf('-sr').stdout
    try:
        path = run(['/sbin/route', '-n', 'get', CLIENT_ALIAS]).stdout
        assert not re.search(r'^\s*destination:\s*' + re.escape(CLIENT_ALIAS) + r'\s*$', path, re.M), 'Alias route exists'
        run(['sudo', '-n', '/sbin/route', '-n', 'add', '-host', CLIENT_ALIAS, '-interface', server_tunnel])
        owned_route = True
        pf('-n', '-a', anchor, '-f', rules)
        pf('-a', anchor, '-f', rules)
        for thread in threads:
            thread.start()
        yield counts
    except BaseException:
        print('Managed web counts: ' + json.dumps(counts), flush=True)
        print('Managed web anchor: ' + pf('-a', anchor, '-sr').stdout + pf('-a', anchor, '-sn').stdout, flush=True)
        print('Managed web states: ' + pf('-a', anchor, '-ss', ok=False).stdout, flush=True)
        print('Managed DNS receipt: ' + run(['/usr/sbin/scutil', '--dns']).stdout, flush=True)
        raise
    finally:
        pf('-a', anchor, '-F', 'rules')
        pf('-a', anchor, '-F', 'nat')
        pf('-k', CLIENT_ALIAS, ok=False)
        if owned_route:
            path = run(['/sbin/route', '-n', 'get', CLIENT_ALIAS]).stdout
            assert re.search(r'^\s*interface:\s*' + re.escape(server_tunnel) + r'\s*$', path, re.M)
            run(['sudo', '-n', '/sbin/route', '-n', 'delete', '-host', CLIENT_ALIAS, '-interface', server_tunnel])
        for service, thread in zip([dns, http_service], threads):
            if thread.is_alive():
                service.shutdown(); thread.join(timeout=3)
            service.server_close()
        assert pf('-sr').stdout == before, 'Root PF rules changed'


def verify_web(run, probe, counts, client_tunnel, fallback=False, split=False, requests=3, managed=False):
    assert requests in (1, 3, 9)
    preflight = time.monotonic()
    resolver = '1.1.1.1' if fallback else DNS
    path = run(['/sbin/route', '-n', 'get', resolver]).stdout
    assert re.search(r'^\s*interface:\s*' + re.escape(client_tunnel) + r'\s*$', path, re.M), 'DNS bypassed the VPN: ' + path
    receipt = run(['/usr/sbin/scutil', '--dns']).stdout.split('resolver #2', 1)[0]
    active = re.findall(r'nameserver\[[0-9]+\]\s*:\s*([0-9.]+)', receipt)
    if managed or split:
        # Some macOS scutil versions display the uint16 port as signed.
        # Compare the actual 16 bits with the native dictionary recorded before
        # publication, rather than assuming that display text is positive.
        journal = json.loads(run(['sudo', '-n', 'cat', '/var/run/vpn-navigator/dns.journal']).stdout)
        key = 'Setup:/Network/Service/' + journal['service'] + '/DNS'
        published = plistlib.loads(base64.b64decode(journal['applied'][key], validate=True))
        shown = re.search(r'port\s*:\s*(-?[0-9]+)', receipt)
        port = published.get('ServerPort', 53)
        assert active == ['127.0.0.1'] and published['ServerAddresses'] == active and \
            (port == 53 or 1023 < port <= 65535) and \
            ((int(shown[1]) & 65535) == port if shown else port == 53), \
            'Loopback split DNS was not actually applied: ' + receipt
        # IPv4-only fixture; retain a physical IPv6 resolver only if the host
        # actually has that physical path. Candidate policy is covered by core
        # tests; here verify the selected resolver's real kernel route.
        physical6 = run(['/sbin/route', '-n', 'get', '-inet6', 'default'], ok=False).stdout
        has6 = re.search(r'^\s*interface:\s*en[0-9]+\s*$', physical6, re.M)
        global_dns = plistlib.loads(base64.b64decode(journal['managedGlobal'], validate=True))['ServerAddresses']
        candidates = journal.get('physicalResolvers', []) + ['223.5.5.5', '223.6.6.6', '119.29.29.29']
        country_file = Path(probe).parent / 'managed-rules.txt'
        country = [ipaddress.ip_network(line) for line in country_file.read_text().splitlines() if line and not line.startswith('#')]
        private = [ipaddress.ip_network(prefix) for prefix in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7']]
        special = [ipaddress.ip_network(prefix) for prefix in ['0.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
            '169.254.0.0/16', '192.0.0.0/24', '192.0.2.0/24', '192.88.99.0/24', '198.18.0.0/15',
            '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4']]
        local = []
        for family in ['inet', 'inet6']:
            table = run(['/usr/sbin/netstat', '-rn', '-f', family]).stdout
            for line in table.splitlines():
                fields = line.split()
                if len(fields) < 4 or not fields[1].startswith('link#') or 'H' in fields[2] or not re.fullmatch('en[0-9]+', fields[3]):
                    continue
                value = fields[0]
                if family == 'inet':
                    address, _, mask = value.partition('/')
                    octets = address.split('.')
                    value = '.'.join(octets + ['0'] * (4 - len(octets))) + '/' + (mask or str(len(octets) * 8))
                try:
                    local.append(ipaddress.ip_network(value, strict=False))
                except ValueError:
                    pass
        known = {'223.5.5.5', '223.6.6.6', '119.29.29.29', '2400:3200::1', '2400:3200:baba::1', '2402:4e00::', '2402:4e00:1::'}
        selected = []
        for raw in candidates:
            try:
                ip = ipaddress.ip_address(raw)
            except ValueError:
                continue
            if str(ip) in global_dns or ip.is_unspecified or ip.is_loopback or ip.is_multicast or ip.is_link_local:
                continue
            if ip.version == 6 and (not has6 or '%' in raw or ip.ipv4_mapped):
                continue
            on_link = any(ip.version == net.version and ip in net for net in local)
            if not on_link:
                if any(ip.version == net.version and ip in net for net in special):
                    continue
                if str(ip) not in known and not any(ip.version == net.version and ip in net for net in private + country):
                    continue
            if str(ip) not in selected:
                selected.append(str(ip))
            if len(selected) == 2:
                break
        for server in selected if split else []:
            direct = run(['/sbin/route', '-n', 'get', server]).stdout
            assert re.search(r'^\s*interface:\s*en[0-9]+\s*$', direct, re.M), 'Domestic DNS did not use physical route: ' + direct
    else:
        assert active and (set(active) == {'1.1.1.1', '9.9.9.9'} if fallback else active == [DNS]), 'Server DNS was not actually applied: ' + receipt
    before = json.loads(run([probe, '--traffic']).stdout)
    print(f'METRIC: managed web preflight seconds={time.monotonic() - preflight:.3f}', flush=True)
    timings = []
    for _ in range(requests):
        host = uuid.uuid4().hex + '.vpnnav.test'
        for cache_state in ['cold', 'warm']:
            started = time.monotonic()
            result = run(['/usr/bin/curl', '--noproxy', '*', '--fail', '--silent', '--show-error',
                '--max-time', '5', '--connect-timeout', '3', '--http1.1',
                '--cacert', str(Path(probe).parent / 'ca.crt'), '--write-out', '\n%{json}',
                'https://' + host + '/'], ok=False, timeout=10)
            assert result.returncode == 0, 'First-attempt system DNS/HTTPS failed: ' + result.stderr
            body, metrics = result.stdout.rsplit('\n', 1)
            assert body.startswith('vpnnav-managed-web:' + host + ':') and len(body) > 8192
            timing = json.loads(metrics)
            timing = {key: timing[key] for key in ['time_namelookup', 'time_connect', 'time_appconnect', 'time_starttransfer', 'time_total']}
            timing['wall_seconds'] = time.monotonic() - started
            timing['cache_state'] = cache_state
            timings.append(timing)
            print('METRIC: first-attempt system DNS/HTTPS ' + json.dumps(timing), flush=True)
            assert timing['time_namelookup'] < 2 and timing['time_total'] < 3 and timing['wall_seconds'] < 4, 'System DNS/HTTPS exceeded isolated latency budget: ' + str(timing)
    assert counts['dns'] > 0 and counts['http'] > 0, 'HTTP used a non-VPN shortcut'
    for _ in range(30):
        after = json.loads(run([probe, '--traffic']).stdout)
        if after['received'] - before['received'] >= 8192 and after['sent'] > before['sent']:
            print('PASS: system DNS and IPv4 HTTP traverse the encrypted VPN; DNS in a direct prefix stays in the tunnel.', flush=True)
            return timings
        time.sleep(.2)
    raise AssertionError('DNS/HTTP did not increase real encrypted byte counters')
