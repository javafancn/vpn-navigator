import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('web_latency', Path(__file__).parents[1] / 'sample-web-latency.py')
sampler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sampler)


class WebLatencySamplerTests(unittest.TestCase):
    def response(self, args, **kwargs):
        self.assertEqual(args[:2], ['/usr/bin/curl', '-q'])
        self.assertIn('--head', args)
        self.assertIn('--max-time', args)
        self.assertNotIn('--insecure', args)
        return subprocess.CompletedProcess(args, 0, json.dumps({
            'time_namelookup': .2, 'time_connect': .4, 'time_appconnect': .6,
            'time_starttransfer': .8, 'time_total': 1, 'http_code': 200,
            'http_version': '2', 'remote_ip': '192.0.2.1', 'url': 'private-unused-field'}))

    def test_probe_splits_intervals_and_only_exports_allowed_fields(self):
        result = sampler.probe(sampler.HOSTS[0], run=self.response)
        self.assertTrue(result['ok'])
        for key in ['dns_ms', 'tcp_ms', 'tls_ms', 'after_tls_ms']:
            self.assertEqual(result[key], 200)
        self.assertEqual(result['ttfb_ms'], 800)
        self.assertNotIn('private-unused-field', json.dumps(result))

    def test_failed_and_invalid_probes_do_not_become_zero_latency_successes(self):
        for output in ['invalid json', json.dumps({'time_namelookup': float('nan')})]:
            result = sampler.probe(sampler.HOSTS[0], run=lambda *a, **k: subprocess.CompletedProcess(a, 7, output))
            summary = sampler.summarize([result])[sampler.HOSTS[0]]
            self.assertEqual(summary['successes'], 0)
            self.assertEqual(summary['failures'], 1)
            self.assertEqual(summary['timings'], {})
        def timeout(*args, **kwargs):
            raise subprocess.TimeoutExpired(args[0], 15)
        self.assertFalse(sampler.probe(sampler.HOSTS[0], run=timeout)['ok'])

    def test_median_p90_and_failures_are_separate(self):
        rows = []
        for i in range(1, 10):
            row = sampler.probe(sampler.HOSTS[0], run=self.response)
            row['dns_ms'] = i
            rows.append(row)
        rows.append({'host': sampler.HOSTS[0], 'ok': False})
        summary = sampler.summarize(rows)[sampler.HOSTS[0]]
        self.assertEqual(summary['timings']['dns_ms'], {'median': 5, 'p90': 9})
        self.assertEqual((summary['successes'], summary['failures']), (9, 1))

    def test_session_observation_and_stale_history(self):
        now = (dt.datetime.now(dt.timezone.utc) - sampler.REFERENCE).total_seconds()
        row = {'beganAt': now-100, 'lastObservedAt': now, 'attemptID': 'example-attempt',
               'outcome': 'observing', 'events': [{'mode': 'China Direct', 'date': now-100},
               {'mode': 'Full VPN', 'date': now-10}], 'profileName': 'must-not-be-exported'}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'history.json'
            path.write_text(json.dumps({'records': [row]}))
            metadata = sampler.session_metadata(path)
            self.assertEqual(metadata['mode'], 'Full VPN')
            self.assertIsNotNone(sampler.identity(metadata))
            self.assertNotIn('profileName', metadata)
            row['lastObservedAt'] = now-120
            path.write_text(json.dumps({'records': [row]}))
            self.assertIsNone(sampler.identity(sampler.session_metadata(path)))
            path.write_text('{broken')
            self.assertTrue(sampler.session_metadata(path)['unavailable'])

    def test_comparison_never_calls_reconnected_or_mode_changed_sessions_same(self):
        metadata = {'fresh': True, 'outcome': 'observing', 'mode': 'China Direct',
                    'mode_since': 1, 'attempt_id': 'first', 'began_at': 'date'}
        summary = sampler.summarize([sampler.probe(sampler.HOSTS[0], run=self.response)])
        baseline = {'schema': 1, 'hosts': list(sampler.HOSTS), 'label': 'evening',
                    'session_before': metadata, 'session_stable': True, 'summary': summary}
        sampler.validate_baseline(baseline)
        current = dict(baseline)
        self.assertTrue(sampler.compare(current, baseline)['same_observed_session_and_mode'])
        for edit in [{'attempt_id': 'second'}, {'mode_since': 2}, {'fresh': False}]:
            current['session_before'] = dict(metadata, **edit)
            self.assertFalse(sampler.compare(current, baseline)['same_observed_session_and_mode'])
        current['session_before'] = metadata
        current['session_stable'] = False
        self.assertFalse(sampler.compare(current, baseline)['same_observed_session_and_mode'])
        baseline['summary'] = {'bad': {}}
        with self.assertRaises(KeyError):
            sampler.validate_baseline(baseline)


if __name__ == '__main__':
    unittest.main()
