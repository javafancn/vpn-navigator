"""Real system DNS -> IPv4 HTTP through TLS, without Darwin's LOCAL shortcut.

The isolated server pushes ordinary client-nat and iroute for a non-local source.
Only server-side packets are redirected to disposable DNS/HTTP responders. The
client must select its real VPN routes; curl uses the system resolver unchanged.
"""
import contextlib
import http.server
import ipaddress
import json
import os
import re
import socket
import socketserver
import struct
import sys
import threading
import time
import uuid

DNS = '1.2.4.8'
WEB = '198.19.100.80'
CLIENT_ALIAS = '198.18.254.99'


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
                        answer = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 0, 4) + socket.inet_aton(WEB)
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
    http_service = http.server.ThreadingHTTPServer(('0.0.0.0', 0), HTTPHandler)
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in [dns, http_service]]
    anchor = 'com.apple/zzz.vpnnav-data-' + uuid.uuid4().hex
    def pf(*args, ok=True):
        return run(['sudo', '-n', '/sbin/pfctl', *args], ok=ok)
    rules = folder / 'managed-web.pf'
    rules.write_text(
        f'rdr pass on {server_tunnel} inet proto udp from {CLIENT_ALIAS} to {{ {DNS}, 1.1.1.1, 9.9.9.9 }} port 53 -> 198.18.254.1 port {dns.server_address[1]}\n'
        f'rdr pass on {server_tunnel} inet proto tcp from {CLIENT_ALIAS} to {WEB} port 80 -> 198.18.254.1 port {http_service.server_address[1]}\n')
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


def verify_web(run, probe, counts, client_tunnel, fallback=False):
    resolver = '1.1.1.1' if fallback else DNS
    path = run(['/sbin/route', '-n', 'get', resolver]).stdout
    assert re.search(r'^\s*interface:\s*' + re.escape(client_tunnel) + r'\s*$', path, re.M), 'DNS bypassed the VPN: ' + path
    before = json.loads(run([probe, '--traffic']).stdout)
    result = None
    for _ in range(3):
        host = uuid.uuid4().hex + '.vpnnav.test'
        result = run(['/usr/bin/curl', '--noproxy', '*', '--fail', '--silent', '--show-error',
            '--max-time', '12', '--connect-timeout', '6', '--http1.1', 'http://' + host + '/'], ok=False, timeout=20)
        if result.returncode == 0:
            assert result.stdout.startswith('vpnnav-managed-web:' + host + ':') and len(result.stdout) > 8192
            break
        time.sleep(1)
    assert result is not None and result.returncode == 0, 'System DNS/HTTP failed: ' + (result.stderr if result else '')
    assert counts['dns'] > 0 and counts['http'] > 0, 'HTTP used a non-VPN shortcut'
    for _ in range(30):
        after = json.loads(run([probe, '--traffic']).stdout)
        if after['received'] - before['received'] >= 8192 and after['sent'] > before['sent']:
            print('PASS: system DNS and IPv4 HTTP traverse the encrypted VPN; DNS in a direct prefix stays in the tunnel.', flush=True)
            return
        time.sleep(.2)
    raise AssertionError('DNS/HTTP did not increase real encrypted byte counters')
