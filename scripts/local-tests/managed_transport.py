"""Disposable macOS CI: real transport to a numeric test endpoint, no app bypass.

PF sends only the reserved documentation endpoint/temporary port to a local
server. The production helper still observes the real physical gateway, does
TLS, creates utun, and installs/verifies real routes without test overrides.
"""
import contextlib
import os
import re
import socket
import socketserver
import sys
import threading
import uuid

ENDPOINT = '203.0.113.7'


@contextlib.contextmanager
def transport(run, folder, port, protocol):
    assert sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
    assert protocol in ('tcp', 'udp') and 1024 < port < 65536
    anchor = 'com.apple/zzz.vpnnav-ci-' + uuid.uuid4().hex
    def pf(*args, ok=True):
        return run(['sudo', '-n', '/sbin/pfctl', *args], ok=ok)
    before = pf('-sr').stdout
    nat = pf('-sn').stdout
    assert 'rdr-anchor "com.apple/*"' in nat, 'Stock macOS redirect anchor required'
    path = run(['/sbin/route', '-n', 'get', ENDPOINT]).stdout
    interface = re.search(r'^\s*interface:\s*((?:en|bridge)[0-9]+)\s*$', path, re.M)
    assert interface, 'Fixture requires a physical endpoint path'
    assert not pf('-a', anchor, '-sr').stdout.strip()
    rules = folder / ('transport-' + protocol + '.conf')
    rules.write_text(
        f'rdr pass on lo0 inet proto {protocol} from any to {ENDPOINT} port {port} -> 127.0.0.1 port {port}\n'
        f'pass out quick on {interface[1]} route-to (lo0 127.0.0.1) inet proto {protocol} from any to {ENDPOINT} port {port} no state\n')
    rules.chmod(0o600)
    token = None
    try:
        pf('-n', '-a', anchor, '-f', rules)
        pf('-a', anchor, '-f', rules)
        enabled = pf('-E')
        receipt = re.search(r'Token\s*:\s*([0-9]+)', enabled.stdout + enabled.stderr)
        assert receipt, 'No owned PF enable token'
        token = receipt[1]
        yield ENDPOINT
    finally:
        # Flush only this disposable anchor's filter/NAT rules, never global PF.
        pf('-a', anchor, '-F', 'rules')
        pf('-a', anchor, '-F', 'nat')
        pf('-k', '0.0.0.0/0', '-k', ENDPOINT, ok=False)
        if token is not None:
            pf('-X', token)
        assert pf('-sr').stdout == before, 'Root PF rules changed'


def self_test(run, folder):
    class TCP(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.sendall(self.request.recv(128))
    class UDP(socketserver.BaseRequestHandler):
        def handle(self):
            data, sock = self.request
            sock.sendto(data, self.client_address)
    for protocol, server_type, handler in [('tcp', socketserver.ThreadingTCPServer, TCP),
                                            ('udp', socketserver.ThreadingUDPServer, UDP)]:
        with server_type(('127.0.0.1', 0), handler) as server:
            server.daemon_threads = True
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with transport(run, folder, server.server_address[1], protocol) as host:
                    kind = socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM
                    with socket.socket(socket.AF_INET, kind) as client:
                        client.settimeout(6)
                        client.connect((host, server.server_address[1]))
                        client.sendall(b'vpnnav-real-transport')
                        assert client.recv(128) == b'vpnnav-real-transport'
                    print('PASS: real ' + protocol.upper() + ' transport reaches isolated server through a physical-looking reserved endpoint; no route or main PF changes.', flush=True)
            finally:
                server.shutdown()
                thread.join(timeout=3)


if __name__ == '__main__':
    import pathlib
    import subprocess
    import tempfile
    def run(args, ok=True):
        result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=15)
        if ok and result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result
    with tempfile.TemporaryDirectory(prefix='vpnnav-transport-') as directory:
        self_test(run, pathlib.Path(directory))
