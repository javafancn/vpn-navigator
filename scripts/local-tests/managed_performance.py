"""Performance gates for the installed engine on an isolated macOS runner.

Scoped utun addresses prevent Darwin's same-host LOCAL shortcut. Compare modes
on the same engine, transport and runner; these are regression budgets, not a
claim about a subscriber's ISP or a public VPN service.
"""
import hashlib
import json
import math
import os
import socket
import statistics
import subprocess
import threading
import time

SIZE = 32 * 1024 * 1024
SAMPLES = 9
MINIMUM_THROUGHPUT_RATIO = .85


class BaselineDriftError(AssertionError):
    """Host drift or sampling uncertainty prevents a trustworthy comparison."""


def median_bounds(record, direction):
    values = sorted(record['samples_mbps'][direction])
    assert len(values) == SAMPLES, 'Missing fixed-count performance samples'
    assert all(math.isfinite(v) and v > 0 for v in values), 'Invalid bandwidth sample'
    assert abs(statistics.median(values) - record['median_mbps'][direction]) <= .001, 'Median does not match recorded samples'
    # For nine independent stationary samples, ranks 2..8 cover the population
    # median with 1 - 2*(C(9,0)+C(9,1))/2**9 = 96.09375% probability.
    # Host-drift checks still apply; this is not a WAN confidence guarantee.
    return values[1], values[-2]


def cpu_snapshot():
    result = subprocess.run(['/bin/ps', '-S', '-ww', '-axo', 'pid=,time=,comm='],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, 'Cannot collect benchmark process CPU counters'
    values = {}
    for row in result.stdout.splitlines():
        fields = row.split(None, 2)
        if len(fields) != 3:
            continue
        pid, clock, command = fields
        name = command.rsplit('/', 1)[-1]
        if name not in ['openvpn', 'VPNNavigatorHelper']:
            continue
        days, clock = clock.split('-', 1) if '-' in clock else ('0', clock)
        seconds = 0.0
        for component in clock.split(':'):
            seconds = seconds * 60 + float(component)
        values[int(pid)] = (name, int(days) * 86400 + seconds)
    assert sum(name == 'openvpn' for name, _ in values.values()) == 2, 'Expected both fixture VPN engines'
    assert sum(name == 'VPNNavigatorHelper' for name, _ in values.values()) == 1, 'Expected one installed helper'
    return values


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
                            stream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
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
            cpu_before = cpu_snapshot()
            phase_started = time.monotonic()
            fixture_cpu_started = time.process_time()
            try:
                for _ in range(SAMPLES):
                    for direction, command in [('download', b'D'), ('upload', b'U')]:
                        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as client:
                            # The one-byte fixture command is not application
                            # payload. Nagle/delayed ACK interaction must not
                            # dominate a short throughput measurement.
                            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
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
            phase_seconds = time.monotonic() - phase_started
            fixture_cpu_seconds = time.process_time() - fixture_cpu_started
            cpu_after = cpu_snapshot()
            assert cpu_before.keys() == cpu_after.keys(), 'A benchmark engine or helper changed identity'
            cpu_seconds = {'engines': 0.0, 'helper_including_reaped_children': 0.0}
            for pid, (name, seconds) in cpu_before.items():
                key = 'engines' if name == 'openvpn' else 'helper_including_reaped_children'
                cpu_seconds[key] += max(0.0, cpu_after[pid][1] - seconds)
        for _ in range(30):
            after = json.loads(run([probe, '--traffic']).stdout)
            if all(after[key] - before[key] >= SIZE * SAMPLES for key in ['sent', 'received']):
                break
            time.sleep(.2)
        else:
            raise AssertionError('Bulk payload bypassed real encrypted byte counters')
    medians = {key: round(statistics.median(values), 3) for key, values in samples.items()}
    assert all(value >= 16 for value in medians.values()), 'Isolated encrypted stream below 16 Mbit/s: ' + str(samples)
    return {'median_mbps': medians, 'samples_mbps': samples, 'bytes_per_direction': SIZE * SAMPLES,
            'wall_seconds': phase_seconds, 'cpu_seconds': cpu_seconds,
            'fixture_cpu_seconds': fixture_cpu_seconds}


def verify_mode_performance(records, baselines):
    failures = []
    unstable = []
    uncertain = []
    for protocol in ['tcp', 'udp']:
        original = baselines[protocol]
        assert len(original) == 3, 'Missing bracketing Original measurements'
        for index, mode in enumerate(['Full VPN', 'China Direct']):
            actual = records[(protocol, mode)]
            for direction in ['download', 'upload']:
                before = original[index]['median_mbps'][direction]
                after = original[index + 1]['median_mbps'][direction]
                assert before >= 16 and after >= 16, 'Original below absolute throughput floor'
                baseline = math.sqrt(before * after)
                measured = actual['median_mbps'][direction]
                assert measured >= 16, 'Managed mode below absolute throughput floor'
                before_low, before_high = median_bounds(original[index], direction)
                after_low, after_high = median_bounds(original[index + 1], direction)
                measured_low, measured_high = median_bounds(actual, direction)
                reference_low = math.sqrt(before_low * after_low)
                reference_high = math.sqrt(before_high * after_high)
                ratio_low, ratio_high = measured_low / reference_high, measured_high / reference_low
                drift_low, drift_high = before_low / after_high, before_high / after_low
                receipt = {'protocol': protocol, 'mode': mode, 'direction': direction,
                           'original_before_mbps': before, 'original_after_mbps': after,
                           'reference_mbps': baseline, 'measured_mbps': measured,
                           'ratio': measured / baseline,
                           'reference_bounds_mbps': [reference_low, reference_high],
                           'measured_bounds_mbps': [measured_low, measured_high],
                           'ratio_bounds': [ratio_low, ratio_high],
                           'baseline_ratio_bounds': [drift_low, drift_high]}
                print('METRIC: paired performance ' + json.dumps(receipt), flush=True)
                if drift_low > 1.25 or drift_high < .8:
                    unstable.append(receipt)
                elif ratio_high < MINIMUM_THROUGHPUT_RATIO:
                    failures.append(receipt)
                elif ratio_low < MINIMUM_THROUGHPUT_RATIO:
                    uncertain.append(receipt)
    # Report all directions before failing so one anomaly does not hide the
    # other mode/transport evidence. No retry may turn an unstable sample green.
    if failures:
        raise AssertionError('Stable paired performance exceeds 15% regression budget: ' + json.dumps(failures))
    if unstable or uncertain:
        raise BaselineDriftError('INCONCLUSIVE: baseline drift or uncertainty across the 85% retention gate: ' +
                                 json.dumps({'baseline_drift': unstable, 'uncertain_ratios': uncertain}))
    print('PASS: all six TCP/UDP mode combinations meet encrypted upload/download integrity, '
          '16 Mbit/s floor and 85% paired throughput retention with stable Original baselines.', flush=True)


def verify_web_performance(records, baselines):
    """Paired native DNS/HTTPS measurements, independently of bulk throughput.

    Warm means a repeated name with a positive TTL; TLS still uses a fresh curl
    process. Fixed additive allowances avoid ratios of tiny loopback timings.
    """
    failures, unstable = [], []

    def summary(samples, cache, key):
        values = sorted(item[key] for item in samples if item['cache_state'] == cache)
        assert len(values) == SAMPLES, 'Missing fixed-count DNS/HTTPS samples'
        assert all(math.isfinite(value) and value >= 0 for value in values), 'Invalid web latency sample'
        return statistics.median(values), values[math.ceil(.95 * len(values)) - 1]

    for protocol in ['tcp', 'udp']:
        original = baselines[protocol]
        assert len(original) == 3, 'Missing bracketing Original web measurements'
        for index, mode in enumerate(['Full VPN', 'China Direct']):
            for cache in ['cold', 'warm']:
                for key in ['time_namelookup', 'time_connect', 'time_appconnect', 'time_starttransfer', 'time_total']:
                    before, before95 = summary(original[index], cache, key)
                    after, after95 = summary(original[index + 1], cache, key)
                    median, p95 = summary(records[(protocol, mode)], cache, key)
                    reference = math.sqrt(before * after)
                    receipt = {'protocol': protocol, 'mode': mode, 'cache_state': cache, 'phase': key,
                               'median_seconds': median, 'p95_seconds': p95,
                               'reference_median_seconds': reference, 'reference_p95_seconds': max(before95, after95)}
                    print('METRIC: paired DNS/HTTPS ' + json.dumps(receipt), flush=True)
                    if max(before, after) > min(before, after) * 1.25 + .05:
                        unstable.append(receipt)
                    elif median > reference * 1.25 + .02 or p95 > max(before95, after95) * 1.25 + .05:
                        failures.append(receipt)
    if unstable:
        raise BaselineDriftError('INCONCLUSIVE: DNS/HTTPS Original baseline drift: ' + json.dumps(unstable))
    if failures:
        raise AssertionError('Paired DNS/HTTPS latency regression: ' + json.dumps(failures))
    print('PASS: cold/warm native DNS, TCP, TLS, first-byte and total HTTPS median/P95 match bracketing Original latency budgets.', flush=True)
