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
counts = {'direct': [], 'direct-backup': [], 'vpn': [], 'vpn-backup': []}
lock = threading.Lock()


def answer(packet, path, tcp):
    p, labels = 12, []
    while packet[p]:
        n = packet[p]; labels.append(packet[p+1:p+1+n].decode('ascii')); p += n + 1
    name = '.'.join(labels).lower(); end = p + 5
    kind = struct.unpack('!H', packet[p+1:p+3])[0]
    with lock:
        counts[path].append((name, tcp))
    direct = path.startswith('direct')
    backup = path.endswith('backup')
    if name.startswith('timeout.') or (name.startswith('blackhole.') and not backup):
        return None
    if name.startswith('domestic-down.') and direct:
        return None
    if name.startswith('slow.') and not backup:
        time.sleep(.9)
    if name.startswith('refused.') and direct:
        return packet[:2] + struct.pack('!HHHHH', 0x8185, 1, 0, 0, 0) + packet[12:end]
    if name.startswith('spoof.') and direct:
        return bytes([packet[0] ^ 1, packet[1]]) + struct.pack('!HHHHH', 0x8180, 1, 0, 0, 0) + packet[12:end]
    if name.startswith('truncated.') and not tcp:
        return packet[:2] + struct.pack('!HHHHH', 0x8380, 1, 0, 0, 0) + packet[12:end]
    if not direct and not name.startswith('healthy.'):
        time.sleep(.18)  # Deterministic distant VPN resolver latency.
    if kind == 28:
        ip = socket.inet_pton(socket.AF_INET6, '2001:db8::' + ('1' if direct else '2'))
    else:
        ip = socket.inet_aton('192.0.2.' + ('1' if direct else '2'))
    ttl = 2 if name.startswith('cache.') else 0
    record = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, ttl, len(ip)) + ip
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
for path in counts:
    tcp = TCP(('127.0.0.1', 0), TCPHandler)
    udp = UDP(('127.0.0.1', tcp.server_address[1]), UDPHandler)
    for service in [tcp, udp]:
        service.path = path; services.append(service)
        threading.Thread(target=service.serve_forever, daemon=True).start()

helper = subprocess.Popen([sys.argv[1], '--self-test-split-dns', *[str(services[i].server_address[1]) for i in [0, 2, 4, 6]],
    str(Path('Resources/Rules/china-dns-domains.txt').resolve())],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    assert select.select([helper.stdout], [], [], 12)[0], 'Relay readiness timed out'
    line = helper.stdout.readline().strip()
    assert line.startswith('DNS_PROXY_PORT='), line + helper.stderr.read() if helper.poll() is not None else line
    port = int(line.split('=')[1])
    assert port > 1023

    def query(name, tcp=False, kind=1, stream=None, ident=None):
        ident = os.urandom(2) if ident is None else ident
        question = b''.join(bytes([len(s)])+s.encode() for s in name.strip('.').split('.') if s) + b'\0' + struct.pack('!HH', kind, 1)
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

    # Completed UDP flows have no EOF. More than 64 distinct source ports
    # must work within the old ten-second retention window without a retry.
    started = time.monotonic()
    for i in range(1000):
        assert query(f'healthy.churn{i}.baidu.com')[-1] == 1
    print(f'METRIC: 1000 independent first-attempt UDP queries seconds={time.monotonic()-started:.3f}')

    # A burst beyond the 128 active-request budget must queue without losing
    # requests. Every primary delays these names. No client retries are used.
    burst = []
    try:
        for i in range(160):
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.connect(('127.0.0.1', port)); sock.settimeout(8)
            name = f'slow.burst{i}.baidu.com'
            ident = struct.pack('!H', i)
            question = b''.join(bytes([len(s)]) + s.encode() for s in name.split('.')) + b'\0\0\1\0\1'
            sock.send(ident + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + question)
            burst.append((sock, ident))
        for sock, ident in burst:
            response = sock.recv(65535)
            assert response[:2] == ident and response[-1] == 1, 'Active UDP request lost under churn'
    finally:
        for sock, _ in burst:
            sock.close()
    print('PASS: 160 distinct UDP queries survive the 128-active-request budget without client retry.')

    # Independent local clients can reuse the same original transaction ID.
    # Pooling upstream sockets must keep their questions and policy groups
    # separate and restore each client's original ID after demultiplexing.
    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        results = list(pool.map(lambda i: query(
            f'slow.shared-id{i}.' + ('baidu.com' if i % 2 else 'foreign.test'),
            ident=b'\xab\xcd'), range(64)))
        assert [response[-1] for response in results] == [1 if i % 2 else 2 for i in range(64)]
    print('PASS: concurrent UDP clients sharing a transaction ID retain question and resolver-policy isolation.')

    for tcp in [False, True]:
        assert query('healthy.baidu.com', tcp)[-1] == 1
        assert query('healthy.foreign.test', tcp)[-1] == 2
        assert query('.', tcp)[-1] == 2
        for kind in [1, 28]:
            assert query('www.baidu.com', tcp, kind)[-1] == 1
            assert query('baidu.com.evil.test', tcp, kind)[-1] == 2
            assert query('www.google.com', tcp, kind)[-1] == 2
        assert query('refused.baidu.com', tcp)[-1] == 2
        assert query('spoof.baidu.com', tcp)[-1] == 2
        # A silent or slow primary must not impose its two-second timeout on
        # every lookup. Both policy groups hedge only to their own backup.
        for suffix, expected in [('baidu.com', 1), ('foreign.test', 2)]:
            for failure in ['blackhole', 'slow']:
                start = time.monotonic()
                assert query(failure + '.' + suffix, tcp)[-1] == expected
                elapsed = time.monotonic() - start
                assert .20 <= elapsed < 1.5, (failure, suffix, tcp, elapsed)
                print(f'METRIC: hedged DNS {failure} {suffix} tcp={tcp} seconds={elapsed:.3f}')
        # Exhaust domestic resolvers before VPN fallback; never race groups.
        start = time.monotonic()
        assert query('domestic-down.baidu.com', tcp)[-1] == 2
        assert 2.0 <= time.monotonic() - start < 4
    assert query('truncated.baidu.com')[2] & 2
    assert query('truncated.baidu.com', tcp=True)[-1] == 1
    with socket.create_connection(('127.0.0.1', port), timeout=3) as stream:
        for name in ['www.baidu.com', 'www.google.com', 'www.bilibili.com']:
            assert query(name, tcp=True, stream=stream)[-1] == (2 if 'google' in name else 1)
    # Model a real system resolver: many pending requests on one UDP flow.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as shared:
        shared.connect(('127.0.0.1', port)); shared.settimeout(8)
        pending = {}
        for i in range(20):
            name = ('multiplex' + str(i) + '.baidu.com') if i % 2 else ('multiplex' + str(i) + '.foreign.test')
            ident = struct.pack('!H', i)
            question = b''.join(bytes([len(s)]) + s.encode() for s in name.split('.')) + b'\0\0\1\0\1'
            shared.send(ident + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + question)
            pending[ident] = 1 if i % 2 else 2
        while pending:
            response = shared.recv(65535)
            assert response[-1] == pending.pop(response[:2])
    # Reclaiming idle flows must preserve an older flow that has an upstream
    # request pending, even while many newer flows complete successfully.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as shared:
        shared.connect(('127.0.0.1', port)); shared.settimeout(4)
        question = b'\x04slow\x05baidu\x03com\0\0\1\0\1'
        ident = b'\xf1\x23'
        shared.send(ident + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + question)
        for i in range(128):
            assert query(f'healthy.pending-churn{i}.baidu.com')[-1] == 1
        response = shared.recv(65535)
        assert response[:2] == ident and response[-1] == 1, 'In-flight UDP client was evicted'
        assert query('healthy.reused.baidu.com', stream=shared)[-1] == 1
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
    assert not any(name.endswith('foreign.test') or name.endswith('google.com') or name.endswith('evil.test')
                   for path in ['direct', 'direct-backup'] for name, _ in counts[path])
    assert not any(name == 'healthy.baidu.com' for name, _ in counts['direct-backup']), 'Healthy queries broadcast to backup'
    assert not any(name == 'healthy.foreign.test' for name, _ in counts['vpn-backup']), 'Healthy VPN queries broadcast to backup'
    print('PASS: real loopback-only split DNS UDP/TCP, A/AAAA, concurrent requests, framed persistent TCP, TC retry, forged/refused response failover, VPN-only failure and domain boundaries.')
    print(f'METRIC: domestic DNS {sum(direct)/len(direct)*1000:.1f}ms vs simulated remote DNS {sum(remote)/len(remote)*1000:.1f}ms; no user network latency claim.')

    # TTL wire caching must restore each caller's ID, age TTLs, expire, and
    # keep UDP/TCP responses isolated. Other fixture answers retain TTL zero.
    for tcp in [False, True]:
        name = 'cache.ttl.baidu.com'
        before = sum(1 for n, t in counts['direct'] if n == name and t == tcp)
        first = query(name, tcp=tcp)
        assert query(name, tcp=tcp, ident=b'\x98\x76')[-1] == 1
        assert sum(1 for n, t in counts['direct'] if n == name and t == tcp) == before + 1
        time.sleep(1.05)
        aged = query(name, tcp=tcp)
        assert struct.unpack('!I', aged[-10:-6])[0] == 1, 'Cache did not age the RR TTL'
        time.sleep(1.05)
        assert query(name, tcp=tcp)[-1] == 1
        assert sum(1 for n, t in counts['direct'] if n == name and t == tcp) == before + 2, 'Expired response was reused'
    barrier = threading.Barrier(32)
    def shared_query(_):
        barrier.wait(timeout=5)
        return query('coalesce.foreign.test')
    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        assert all(packet[-1] == 2 for packet in pool.map(shared_query, range(32)))
    assert sum(1 for name, _ in counts['vpn'] if name == 'coalesce.foreign.test') == 1, 'Identical in-flight queries were not coalesced'
    assert query('coalesce.foreign.test')[-1] == 2
    assert sum(1 for name, _ in counts['vpn'] if name == 'coalesce.foreign.test') == 2, 'TTL-zero answer was cached'
    print('PASS: positive wire cache restores IDs, ages/expires TTLs, separates UDP/TCP and coalesces concurrent queries without caching TTL-zero answers.')
    for tcp in [False, True]:
        assert query('cache.switch.baidu.com', tcp=tcp)[-1] == 1
    crossing = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    crossing.settimeout(3)
    crossing_name = b'\x07timeout\x05baidu\x03com\0\0\1\0\1'
    crossing.sendto(b'\x55\x66' + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + crossing_name, ('127.0.0.1', port))
    time.sleep(.03)
    previous_port = port
    helper.stdin.write('FULL\n'); helper.stdin.flush()
    assert select.select([helper.stdout], [], [], 12)[0], 'Full VPN policy switch timed out'
    line = helper.stdout.readline().strip()
    assert line.startswith('DNS_PROXY_PORT='), line
    port = int(line.split('=')[1])
    assert port == previous_port, 'Live policy switch changed the resolver port'
    retired = crossing.recv(65535); crossing.close()
    assert retired[:2] == b'\x55\x66' and retired[3] & 15 == 2, 'Old-policy request survived a mode switch'
    before_direct = sum(len(counts[path]) for path in ['direct', 'direct-backup'])
    for tcp in [False, True]:
        assert query('cache.switch.baidu.com', tcp=tcp)[-1] == 2, 'Old domestic cache crossed the mode boundary'
        for name in ['www.baidu.com', 'www.bilibili.com', 'www.google.com']:
            assert query(name, tcp=tcp)[-1] == 2
        start = time.monotonic()
        assert query('blackhole.baidu.com', tcp=tcp)[-1] == 2
        assert time.monotonic() - start < 1.5, 'Full VPN retained a stalled primary resolver'
    assert sum(len(counts[path]) for path in ['direct', 'direct-backup']) == before_direct, 'Full VPN sent a query to domestic DNS'
    print('PASS: Full VPN domestic/foreign queries remain VPN-only, with bounded primary DNS failover over UDP/TCP.')

    def restart(*options):
        global helper, port
        helper.stdin.write('STOP\n'); helper.stdin.flush(); helper.stdin.close()
        helper.wait(timeout=5)
        assert helper.returncode == 0
        helper = subprocess.Popen([sys.argv[1], '--self-test-split-dns',
            *[str(services[i].server_address[1]) for i in [0, 2, 4, 6]],
            str(Path('Resources/Rules/china-dns-domains.txt').resolve()), *options],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert select.select([helper.stdout], [], [], 12)[0], 'Relay restart timed out'
        line = helper.stdout.readline().strip()
        assert line.startswith('DNS_PROXY_PORT='), line
        port = int(line.split('=')[1])

    for option, missing in [('--ipv4-only', 28), ('--ipv6-only', 1)]:
        restart(option)
        before = sum(len(values) for values in counts.values())
        for tcp in [False, True]:
            for domain in ['www.baidu.com', 'www.google.com']:
                started = time.monotonic()
                empty = query(domain, tcp=tcp, kind=missing)
                assert empty[3] & 15 == 0 and empty[6:12] == b'\0' * 6
                assert time.monotonic() - started < .5, 'Unavailable family waited for an upstream timeout'
        assert sum(len(values) for values in counts.values()) == before, 'Unavailable family reached upstream'
        assert query('www.google.com', kind=1 if missing == 28 else 28)[-1] == 2
    print('PASS: negotiated IPv4-only/IPv6-only policy returns immediate UDP/TCP NODATA for the unavailable family while retaining the available family.')

    # A listener must own UDP and TCP together, without stealing a busy port.
    # Exercise each one-transport conflict with disposable high ports.
    for socktype in [socket.SOCK_STREAM, socket.SOCK_DGRAM]:
        with socket.socket(socket.AF_INET, socktype) as occupied:
            occupied.bind(('127.0.0.1', 0))
            if socktype == socket.SOCK_STREAM:
                occupied.listen()
            busy = occupied.getsockname()[1]
            restart('--port=' + str(busy))
            assert port != busy
            assert query('healthy.baidu.com')[-1] == 1 and query('healthy.baidu.com', tcp=True)[-1] == 1
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as available:
        available.bind(('127.0.0.1', 0)); selected = available.getsockname()[1]
    restart('--port=' + str(selected))
    assert port == selected
    assert query('healthy.baidu.com')[-1] == 1 and query('healthy.baidu.com', tcp=True)[-1] == 1
    print('PASS: preferred port binds both transports; either UDP or TCP conflict falls back without displacing the existing service.')
finally:
    pending = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if helper.poll() is None and 'port' in locals():
        question = b'\x07timeout\x07pending\x07foreign\x04test\0\0\1\0\1'
        pending.sendto(b'\x12\x34' + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + question, ('127.0.0.1', port))
        time.sleep(.03)
    try:
        helper.stdin.write('STOP\n'); helper.stdin.flush(); helper.stdin.close()
    except (BrokenPipeError, OSError):
        pass
    try:
        helper.wait(timeout=5)
    except subprocess.TimeoutExpired:
        helper.kill(); helper.wait(timeout=5)
    pending.close()
    for service in services:
        service.shutdown(); service.server_close()
    assert helper.returncode == 0 and helper.stdout.readline().strip() == 'DNS_PROXY_STOPPED', 'Relay failed graceful stop with an in-flight request'
