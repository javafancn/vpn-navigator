import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('managed_performance',
    Path(__file__).parents[1] / 'local-tests/managed_performance.py')
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


def sample(download, upload=None):
    upload = upload or download
    return {'median_mbps': {'download': download, 'upload': upload},
            'samples_mbps': {'download': [download] * 9, 'upload': [upload] * 9}}


class PairedPerformanceTests(unittest.TestCase):
    def run_gate(self, records, baselines):
        with contextlib.redirect_stdout(io.StringIO()):
            performance.verify_mode_performance(records, baselines)

    def inputs(self):
        records = {(p, mode): sample(100) for p in ['tcp', 'udp']
                   for mode in ['Full VPN', 'China Direct']}
        baselines = {p: [sample(100), sample(110), sample(105)] for p in ['tcp', 'udp']}
        return records, baselines

    def test_stable_bracketing_samples_allow_comparison(self):
        self.run_gate(*self.inputs())

    def test_real_regression_with_stable_baselines_is_rejected(self):
        records, baselines = self.inputs()
        records[('tcp', 'Full VPN')] = sample(100, 49)
        with self.assertRaisesRegex(AssertionError, 'Stable paired performance'):
            self.run_gate(records, baselines)

    def test_changed_host_speed_is_inconclusive_and_never_passes(self):
        records, baselines = self.inputs()
        baselines['tcp'][1] = sample(200)
        with self.assertRaises(performance.BaselineDriftError):
            self.run_gate(records, baselines)

    def test_a_baseline_cannot_be_reused_for_both_managed_modes(self):
        records, baselines = self.inputs()
        baselines['udp'].pop()
        with self.assertRaisesRegex(AssertionError, 'Missing bracketing'):
            self.run_gate(records, baselines)

    def test_absolute_floor_is_independent_of_relative_gate(self):
        records, baselines = self.inputs()
        records[('udp', 'China Direct')] = sample(15)
        with self.assertRaisesRegex(AssertionError, 'absolute throughput floor'):
            self.run_gate(records, baselines)

    def test_uncertainty_crossing_the_gate_does_not_pass(self):
        records, baselines = self.inputs()
        records[('tcp', 'Full VPN')] = {'median_mbps': {'download': 100, 'upload': 88},
            'samples_mbps': {'download': [100] * 9, 'upload': [70, 80, 83, 85, 88, 90, 92, 95, 99]}}
        with self.assertRaises(performance.BaselineDriftError):
            self.run_gate(records, baselines)

    def test_overlapping_baseline_intervals_do_not_claim_proven_host_drift(self):
        records, baselines = self.inputs()
        baselines['tcp'][0] = {'median_mbps': {'download': 100, 'upload': 100},
            'samples_mbps': {key: [70, 80, 90, 95, 100, 105, 110, 120, 140] for key in ['download', 'upload']}}
        baselines['tcp'][1] = {'median_mbps': {'download': 130, 'upload': 130},
            'samples_mbps': {key: [90, 100, 110, 120, 130, 140, 150, 160, 170] for key in ['download', 'upload']}}
        records[('tcp', 'Full VPN')] = sample(150)
        records[('tcp', 'China Direct')] = sample(150)
        # A 30% difference of point estimates alone does not establish drift.
        # All managed lower ratio bounds still comfortably exceed the gate.
        self.run_gate(records, baselines)

    def test_twenty_percent_throughput_regression_cannot_pass(self):
        records, baselines = self.inputs()
        records[('udp', 'China Direct')] = sample(80)
        with self.assertRaisesRegex(AssertionError, 'Stable paired performance'):
            self.run_gate(records, baselines)

    @staticmethod
    def web_sample(seconds):
        keys = ['time_namelookup', 'time_connect', 'time_appconnect', 'time_starttransfer', 'time_total']
        return [dict(cache_state=cache, **{key: seconds for key in keys})
                for cache in ['cold', 'warm'] for _ in range(9)]

    def web_inputs(self):
        records = {(protocol, mode): self.web_sample(.011) for protocol in ['tcp', 'udp'] for mode in ['Full VPN', 'China Direct']}
        baselines = {protocol: [self.web_sample(.01) for _ in range(3)] for protocol in ['tcp', 'udp']}
        return records, baselines

    def test_paired_web_samples_accept_small_loopback_noise(self):
        with contextlib.redirect_stdout(io.StringIO()):
            performance.verify_web_performance(*self.web_inputs())

    def test_web_regression_is_detected_independently_of_throughput(self):
        records, baselines = self.web_inputs()
        records[('tcp', 'Full VPN')][0]['time_total'] = .5
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(AssertionError, 'HTTPS latency regression'):
            performance.verify_web_performance(records, baselines)

    def test_web_baseline_drift_is_inconclusive(self):
        records, baselines = self.web_inputs()
        baselines['udp'][1] = self.web_sample(.2)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(performance.BaselineDriftError):
            performance.verify_web_performance(records, baselines)

    def test_missing_or_invalid_web_samples_cannot_pass(self):
        records, baselines = self.web_inputs()
        records[('udp', 'China Direct')].pop()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(AssertionError, 'fixed-count'):
            performance.verify_web_performance(records, baselines)
        records, baselines = self.web_inputs()
        records[('udp', 'China Direct')][0]['time_namelookup'] = float('nan')
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(AssertionError, 'Invalid web latency'):
            performance.verify_web_performance(records, baselines)

    def test_cpu_accounting_handles_clock_fields_and_spaced_paths(self):
        output = ('12 0:01.25 /Library/Application Support/VPNNavigator/Local/Payload/openvpn\n'
                  '13 1:02.50 /Library/Application Support/VPNNavigator/Local/Payload/openvpn\n'
                  '14 1-00:02:03.75 /Library/Application Support/VPNNavigator/Local/Payload/VPNNavigatorHelper\n'
                  '99 0:99.00 unrelated\n')
        with patch.object(performance.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=output)):
            values = performance.cpu_snapshot()
        self.assertEqual(values[12], ('openvpn', 1.25))
        self.assertEqual(values[13], ('openvpn', 62.5))
        self.assertEqual(values[14], ('VPNNavigatorHelper', 86523.75))


if __name__ == '__main__':
    unittest.main()
