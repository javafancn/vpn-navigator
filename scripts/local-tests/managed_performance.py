"""Performance gates for the installed engine on an isolated macOS runner.

Scoped utun addresses prevent Darwin's same-host LOCAL shortcut. Compare modes
on the same engine, transport and runner; these are regression budgets, not a
claim about a subscriber's ISP or a public VPN service.
"""
import hashlib
import json
import os
import socket
import statistics
import threading
import time

SIZE = 8 * 1024 * 1024
SAMPLES = 3


def receive(sock, size, digest=False):
    result = hashlib.sha256() if digest else bytearray()
    remaining = size
    while remaining:
        chunk = sock.recv(min(256 * 1024, remaining))
        assert chunk, 'Encrypted stream ended before the complete payload'
        remaining -= len(chunk)
        result.update(chunk) if digest else result.extend(chunk)
    return result.digest() if digest else bytes(result)


def encrypted_bandwidth(run, probe, server_tunnel, client_tunnel, aliases):
    block = os.urandom(256 * 1024)
    expected = hashlib.sha256(block * (SIZE // len(block))).digest()
    samples = {'download': [], 'upload': []}
    errors = []
    with aliases([('fe80::1', server_tunnel), ('fe80::2', client_tunnel)]):
        ss, cs = map(socket.if_nametoindex, [server_tunnel, client_tunnel])
        bound = getattr(socket, 'IPV6_BOUND_IF', 125)
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as listener:
            listener.setsockopt(socket.IPPROTO_IPV6, bound, ss)
            listener.bind(('fe80::1', 0, 0, ss))
            listener.listen(4); listener.settimeout(12)
            def server():
                try:
                    for _ in range(SAMPLES * 2):
                        stream, _ = listener.accept()
                        with stream:
                            stream.settimeout(12)
                            command = receive(stream, 1)
                            if command == b'D':
                                for _ in range(SIZE // len(block)):
                                    stream.sendall(block)
                            else:
                                assert command == b'U'
                                assert receive(stream, SIZE, digest=True) == expected, 'Upload corruption'
                                stream.sendall(expected)
                except BaseException as error:
                    errors.append(repr(error))
            worker = threading.Thread(target=server, daemon=True)
            worker.start()
            before = json.loads(run([probe, '--traffic']).stdout)
            try:
                for _ in range(SAMPLES):
                    for direction, command in [('download', b'D'), ('upload', b'U')]:
                        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as client:
                            client.setsockopt(socket.IPPROTO_IPV6, bound, cs)
                            client.bind(('fe80::2', 0, 0, cs)); client.settimeout(12)
                            client.connect(('fe80::1', listener.getsockname()[1], 0, cs))
                            started = time.monotonic(); client.sendall(command)
                            if direction == 'download':
                                assert receive(client, SIZE, digest=True) == expected, 'Download corruption'
                            else:
                                for _ in range(SIZE // len(block)):
                                    client.sendall(block)
                                assert receive(client, 32) == expected, 'Upload acknowledgement mismatch'
                            seconds = time.monotonic() - started
                            samples[direction].append(SIZE * 8 / seconds / 1_000_000)
                            print(f'METRIC: encrypted stream direction={direction} bytes={SIZE} seconds={seconds:.3f} mbps={samples[direction][-1]:.3f}', flush=True)
            finally:
                worker.join(timeout=15)
            assert not worker.is_alive() and not errors, 'Encrypted bandwidth server failed: ' + str(errors)
        for _ in range(30):
            after = json.loads(run([probe, '--traffic']).stdout)
            if all(after[key] - before[key] >= SIZE * SAMPLES for key in ['sent', 'received']):
                break
            time.sleep(.2)
        else:
            raise AssertionError('Bulk payload bypassed real encrypted byte counters')
    medians = {key: round(statistics.median(values), 3) for key, values in samples.items()}
    assert all(value >= 16 for value in medians.values()), 'Isolated encrypted stream below 16 Mbit/s: ' + str(samples)
    return {'median_mbps': medians, 'samples_mbps': samples, 'bytes_per_direction': SIZE * SAMPLES}


def verify_mode_performance(records):
    for protocol in ['tcp', 'udp']:
        original = records[(protocol, 'Original')]
        for mode in ['Full VPN', 'China Direct']:
            actual = records[(protocol, mode)]
            for direction in ['download', 'upload']:
                baseline = original['median_mbps'][direction]
                measured = actual['median_mbps'][direction]
                assert measured >= baseline * .5, (
                    f'{protocol}/{mode}/{direction}: {measured:.1f} Mbit/s vs '
                    f'Original {baseline:.1f}; exceeds 50% regression budget')
    print('PASS: all six TCP/UDP mode combinations meet encrypted upload/download integrity, '
          '16 Mbit/s floor and 50% relative regression budgets.', flush=True)
