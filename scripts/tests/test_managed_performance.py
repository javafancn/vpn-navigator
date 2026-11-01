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
    return {'median_mbps': {'download': download, 'upload': upload or download}}


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
