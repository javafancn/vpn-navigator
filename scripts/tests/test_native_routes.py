from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin routing ABI')
class NativeRoutesTests(unittest.TestCase):
    def test_retained_reader_with_full_notification_queue(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix='vpnnav-reader-backlog-') as folder:
            executable = str(Path(folder) / 'reader-backlog')
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-Dwrite=vpn_test_write',
                            '-I', str(root / 'Sources/CVPNRoutes/include'),
                            str(root / 'Sources/CVPNRoutes/routes.c'),
                            str(root / 'scripts/tests/route_reader_backlog_fixture.c'), '-o', executable],
                           check=True, capture_output=True, text=True, timeout=30)
            result = subprocess.run([executable], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS: five full notification queues', result.stdout)

    def test_production_ipv6_messages_without_kernel_mutations(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix='vpnnav-route-message-') as folder:
            executable = str(Path(folder) / 'route-messages')
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(root / 'Sources/CVPNRoutes/include'),
                            str(root / 'Sources/CVPNRoutes/routes.c'),
                            str(root / 'scripts/tests/native_routes_fixture.c'), '-o', executable],
                           check=True, capture_output=True, text=True, timeout=30)
            result = subprocess.run([executable], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('PASS:', result.stdout)
