#!/usr/bin/env python3
"""Real production relay on macOS; separate bounded local upstreams, no system DNS edits."""
import concurrent.futures
import os
from pathlib import Path
import select
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time

assert sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
counts = {'direct': [], 'vpn': []}
lock = threading.Lock()


def answer(packet, path, tcp):
    p, labels = 12, []
    while packet[p]:
        n = packet[p]; labels.append(packet[p+1:p+1+n].decode('ascii')); p += n + 1
    name = '.'.join(labels).lower(); end = p + 5
    kind = struct.unpack('!H', packet[p+1:p+3])[0]
    with lock:
        counts[path].append((name, tcp))
    if name.startswith('timeout.'):
        return None
    if name.startswith('refused.') and path == 'direct':
        return packet[:2] + struct.pack('!HHHHH', 0x8185, 1, 0, 0, 0) + packet[12:end]
    if name.startswith('spoof.') and path == 'direct':
        return b'\xff\xff' + struct.pack('!HHHHH', 0x8180, 1, 0, 0, 0) + packet[12:end]
    if name.startswith('truncated.') and not tcp:
        return packet[:2] + struct.pack('!HHHHH', 0x8380, 1, 0, 0, 0) + packet[12:end]
    if path == 'vpn':
        time.sleep(.18)  # Deterministic distant VPN resolver latency.
    if kind == 28:
        ip = socket.inet_pton(socket.AF_INET6, '2001:db8::' + ('1' if path == 'direct' else '2'))
    else:
        ip = socket.inet_aton('192.0.2.' + ('1' if path == 'direct' else '2'))
    record = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 0, len(ip)) + ip
    return packet[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + packet[12:end] + record


class UDP(socketserver.ThreadingUDPServer):
    daemon_threads = True


class TCP(socketserver.ThreadingTCPServer):
    daemon_threads = True


def exact(sock, length):
    data = b''
    while len(data) < length:
        chunk = sock.recv(length-len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        result = answer(data, self.server.path, False)
        if result:
            sock.sendto(result, self.client_address)


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        try:
            while True:
                size = struct.unpack('!H', exact(self.request, 2))[0]
                result = answer(exact(self.request, size), self.server.path, True)
                if result:
                    framed = struct.pack('!H', len(result)) + result
                    # Split the length and message across real stream writes.
                    for part in [framed[:1], framed[1:5], framed[5:]]:
                        self.request.sendall(part)
        except (EOFError, OSError):
            pass


services = []
for path in ['direct', 'vpn']:
    tcp = TCP(('127.0.0.1', 0), TCPHandler)
    udp = UDP(('127.0.0.1', tcp.server_address[1]), UDPHandler)
    for service in [tcp, udp]:
        service.path = path; services.append(service)
        threading.Thread(target=service.serve_forever, daemon=True).start()

helper = subprocess.Popen([sys.argv[1], '--self-test-split-dns', str(services[0].server_address[1]),
    str(services[2].server_address[1]), str(Path('Resources/Rules/china-dns-domains.txt').resolve())],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    assert select.select([helper.stdout], [], [], 12)[0], 'Relay readiness timed out'
    line = helper.stdout.readline().strip()
    assert line.startswith('DNS_PROXY_PORT='), line + helper.stderr.read() if helper.poll() is not None else line
    port = int(line.split('=')[1])
    assert port > 1023

    def query(name, tcp=False, kind=1, stream=None):
        ident = os.urandom(2)
        question = b''.join(bytes([len(s)])+s.encode() for s in name.split('.')) + b'\0' + struct.pack('!HH', kind, 1)
        packet = ident + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + question
        owned = stream is None
        sock = stream or socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM)
        try:
            sock.settimeout(8)
            if owned:
                sock.connect(('127.0.0.1', port))
            if tcp:
                framed = struct.pack('!H', len(packet)) + packet
                for part in [framed[:1], framed[1:8], framed[8:]]:
                    sock.sendall(part)
                response = exact(sock, struct.unpack('!H', exact(sock, 2))[0])
            else:
                sock.send(packet); response = sock.recv(65535)
            assert response[:2] == ident and response[12:12+len(question)] == question, 'Question/transaction identity corrupted'
            return response
        finally:
            if owned:
                sock.close()

    for tcp in [False, True]:
        for kind in [1, 28]:
            assert query('www.baidu.com', tcp, kind)[-1] == 1
            assert query('baidu.com.evil.test', tcp, kind)[-1] == 2
            assert query('www.google.com', tcp, kind)[-1] == 2
        assert query('refused.baidu.com', tcp)[-1] == 2
        assert query('spoof.baidu.com', tcp)[-1] == 2
    assert query('truncated.baidu.com')[2] & 2
    assert query('truncated.baidu.com', tcp=True)[-1] == 1
    with socket.create_connection(('127.0.0.1', port), timeout=3) as stream:
        for name in ['www.baidu.com', 'www.google.com', 'www.bilibili.com']:
            assert query(name, tcp=True, stream=stream)[-1] == (2 if 'google' in name else 1)
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        results = list(pool.map(lambda i: query(('a' + str(i) + '.baidu.com') if i % 2 else ('a' + str(i) + '.foreign.test'), tcp=bool(i%3)), range(32)))
        assert [r[-1] for r in results] == [1 if i%2 else 2 for i in range(32)]
    # The relay must not try domestic DNS when ALL VPN resolvers fail.
    start = time.monotonic()
    failed = query('timeout.foreign.test')
    assert failed[3] & 15 == 2 and time.monotonic()-start < 5
    direct = []
    remote = []
    for _ in range(4):
        start = time.monotonic(); query('latency.baidu.com'); direct.append(time.monotonic()-start)
        start = time.monotonic(); query('latency.foreign.test'); remote.append(time.monotonic()-start)
    assert max(direct) < min(remote) and min(remote) >= .16, (direct, remote)
    assert not any(name.endswith('foreign.test') or name.endswith('google.com') or name.endswith('evil.test') for name, _ in counts['direct'])
    print('PASS: real loopback-only split DNS UDP/TCP, A/AAAA, concurrent requests, framed persistent TCP, TC retry, forged/refused response failover, VPN-only failure and domain boundaries.')
    print(f'METRIC: domestic DNS {sum(direct)/len(direct)*1000:.1f}ms vs simulated remote DNS {sum(remote)/len(remote)*1000:.1f}ms; no user network latency claim.')
finally:
    helper.terminate()
    try:
        helper.wait(timeout=5)
    except subprocess.TimeoutExpired:
        helper.kill(); helper.wait(timeout=5)
    for service in services:
        service.shutdown(); service.server_close()
