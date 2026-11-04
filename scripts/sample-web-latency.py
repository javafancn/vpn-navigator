#!/usr/bin/env python3
"""On-demand, read-only WAN samples. JSON on stdout, progress on stderr.

No cache flush, XPC call, VPN restart, browser cookies or configuration changes.
Every HEAD uses a fresh curl process and the current system resolver/routes.
"""
import argparse
import concurrent.futures
import datetime as dt
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys

HOSTS = ('www.youtube.com', 'www.google.com', 'github.com', 'www.cloudflare.com')
HISTORY = Path.home() / 'Library/Application Support/VPNNavigator/ConnectionHistory/history.json'
REFERENCE = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def session_metadata(path=HISTORY):
    """History is an observation, never an authoritative live helper snapshot."""
    try:
        if path.stat().st_size > 2_000_000:
            raise ValueError('oversized history')
        archive = json.loads(path.read_text())
        row = max(archive['records'], key=lambda r: r['beganAt'])
        mode_event = next((e for e in reversed(row.get('events', [])) if e.get('mode')), {})
        observed = REFERENCE + dt.timedelta(seconds=row['lastObservedAt'])
        age = (dt.datetime.now(dt.timezone.utc) - observed).total_seconds()
        return {'attempt_id': row['attemptID'],
                'began_at': (REFERENCE + dt.timedelta(seconds=row['beganAt'])).isoformat(),
                'last_observed_at': observed.isoformat(), 'outcome': row['outcome'],
                'mode': mode_event.get('mode'), 'mode_since': mode_event.get('date'),
                'fresh': 0 <= age <= 90, 'source': 'local_history'}
    except (OSError, ValueError, KeyError, TypeError, OverflowError, AttributeError, IndexError):
        return {'source': 'local_history', 'fresh': False, 'unavailable': True}


def identity(metadata):
    if not metadata.get('fresh') or metadata.get('outcome') != 'observing' or not metadata.get('mode'):
        return None
    return tuple(metadata.get(k) for k in ('attempt_id', 'began_at', 'mode', 'mode_since'))


def probe(host, run=subprocess.run):
    sample = {'host': host, 'at': timestamp()}
    try:
        result = run(['/usr/bin/curl', '-q', '-sS', '--noproxy', '*', '--head',
                      '--output', '/dev/null', '--connect-timeout', '5', '--max-time', '12',
                      '--write-out', '%{json}', 'https://' + host + '/'],
                     capture_output=True, text=True, timeout=15)
        data = json.loads(result.stdout)
        clocks = [float(data[k]) for k in ('time_namelookup', 'time_connect',
                  'time_appconnect', 'time_starttransfer', 'time_total')]
        if not all(math.isfinite(v) and v >= 0 for v in clocks):
            raise ValueError('invalid timing')
        dns, connect, tls, first, total = clocks
        ok = result.returncode == 0 and data['http_code'] > 0 and 0 <= dns <= connect <= tls <= first <= total
        sample.update(ok=ok, exit_code=result.returncode, status=data['http_code'],
                      http_version=data.get('http_version'), remote_ip=data.get('remote_ip'))
        if ok:
            sample.update({k: round(v * 1000, 3) for k, v in {
                'dns_ms': dns, 'tcp_ms': connect - dns, 'tls_ms': tls - connect,
                'after_tls_ms': first - tls, 'ttfb_ms': first, 'total_ms': total}.items()})
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        sample.update(ok=False, error='probe_failed')
    return sample


def summarize(samples):
    summary = {}
    for host in HOSTS:
        rows = [r for r in samples if r['host'] == host]
        good = [r for r in rows if r.get('ok')]
        timings = {}
        for key in ('dns_ms', 'tcp_ms', 'tls_ms', 'after_tls_ms', 'ttfb_ms', 'total_ms'):
            values = sorted(r[key] for r in good)
            if values:
                timings[key] = {'median': round(statistics.median(values), 3),
                                'p90': values[math.ceil(.9 * len(values)) - 1]}
        summary[host] = {'successes': len(good), 'failures': len(rows) - len(good), 'timings': timings}
    return summary


def compare(current, baseline):
    current_identity = identity(current['session_before'])
    baseline_identity = identity(baseline['session_before'])
    same = (current_identity is not None and current_identity == baseline_identity
            and current['session_stable'] and baseline['session_stable'])
    deltas = {}
    for host in HOSTS:
        a = baseline['summary'].get(host, {}).get('timings', {})
        b = current['summary'][host]['timings']
        deltas[host] = {key: round(b[key]['median'] - a[key]['median'], 3)
                        for key in b if key in a}
    return {'baseline_label': baseline.get('label'), 'same_observed_session_and_mode': same,
            'median_delta_ms': deltas}


def validate_baseline(baseline):
    if baseline['schema'] != 1 or baseline['hosts'] != list(HOSTS):
        raise ValueError('incompatible sample')
    if not isinstance(baseline['session_before'], dict) or not isinstance(baseline['session_stable'], bool):
        raise ValueError('invalid session observation')
    identity(baseline['session_before'])
    for host in HOSTS:
        timings = baseline['summary'][host]['timings']
        if not isinstance(timings, dict):
            raise ValueError('invalid summary')
        for value in timings.values():
            median = value['median']
            if not isinstance(median, (int, float)) or not math.isfinite(median) or median < 0:
                raise ValueError('invalid summary median')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True, choices=['evening', 'next-day', 'after-reconnect'])
    parser.add_argument('--samples', type=int, default=9, help='1..30 rounds per host (default: 9)')
    parser.add_argument('--compare', type=Path, help='Earlier JSON sample file')
    args = parser.parse_args()
    if not 1 <= args.samples <= 30:
        parser.error('--samples must be 1..30')
    baseline = None
    if args.compare:
        try:
            if args.compare.stat().st_size > 2_000_000:
                raise ValueError('oversized sample')
            baseline = json.loads(args.compare.read_text())
            validate_baseline(baseline)
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            parser.error('Cannot compare incompatible or unreadable sample: ' + str(error))
    before = session_metadata()
    result = {'schema': 1, 'label': args.label, 'started_at': timestamp(), 'hosts': list(HOSTS),
              'method': 'fresh_process_HEAD_system_DNS_no_proxy', 'session_before': before,
              'notes': ['No cache flush: round 1 may already be warm.',
                        'HEAD timing is not browser page rendering or video throughput.',
                        'Session metadata is a recent local history observation, not live attestation.']}
    samples = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for round_index in range(args.samples):
            for sample in pool.map(probe, HOSTS):
                sample['round'] = round_index + 1
                samples.append(sample)
            print(f'Completed round {round_index + 1}/{args.samples}', file=sys.stderr, flush=True)
    after = session_metadata()
    result.update(finished_at=timestamp(), session_after=after,
                  session_stable=identity(before) is not None and identity(before) == identity(after),
                  samples=samples, summary=summarize(samples))
    if baseline:
        result['comparison'] = compare(result, baseline)
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2, allow_nan=False)
    print()


if __name__ == '__main__':
    main()
