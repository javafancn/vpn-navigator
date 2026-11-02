"""Execute the shipped DNS hook with isolated native-helper/cache boundaries."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DNSHookFailureTests(unittest.TestCase):
    def run_hook(self, *, apply_status=0, cache_status=0, phase='dns-up', address='10.8.0.53'):
        with tempfile.TemporaryDirectory(prefix='vpnnav-dns-hook-') as work:
            folder = Path(work)
            runtime = folder / 'runtime'
            runtime.mkdir(mode=0o700)
            cache = folder / 'cache-refresh'
            cache.write_text('#!/bin/bash\ntouch "$FIXTURE/cache-called"\nexit "$CACHE_STATUS"\n')
            cache.chmod(0o700)
            helper = folder / 'VPNNavigatorHelper'
            helper.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$FIXTURE/helper-args"\nexit "$APPLY_STATUS"\n')
            helper.chmod(0o700)
            source = (ROOT / 'Resources/Engine/macos-dns-updown.sh').read_text()
            source = source.replace('runtime=/var/run/vpn-navigator', 'runtime="' + str(runtime) + '"')
            source = source.replace('/usr/bin/dscacheutil', '"' + str(cache) + '"')
            hook = folder / 'macos-dns-updown.sh'
            hook.write_text(source)
            # Keep only test-specific DNS values, never inherited developer DNS.
            env = {key: value for key, value in os.environ.items() if not key.startswith('dns_')}
            env.update(FIXTURE=str(folder), APPLY_STATUS=str(apply_status), CACHE_STATUS=str(cache_status),
                       dev='utun9999', script_type=phase, dns_server_1_address_1=address)
            result = subprocess.run(['/bin/bash', str(hook)], env=env, capture_output=True, text=True, timeout=5)
            arguments = (folder / 'helper-args').read_text().splitlines() if (folder / 'helper-args').exists() else None
            return result.returncode, arguments, (folder / 'cache-called').exists()

    def test_cache_failure_does_not_override_successful_dns_application(self):
        for cache_status in [0, 1, 127]:
            with self.subTest(cache_status=cache_status):
                code, arguments, cached = self.run_hook(cache_status=cache_status)
                self.assertEqual(code, 0)
                self.assertEqual(arguments[:3], ['--apply-dns', 'utun9999', '10.8.0.53 '])
                self.assertTrue(cached)

    def test_native_dns_failure_still_fails_hook_and_skips_cache(self):
        code, arguments, cached = self.run_hook(apply_status=1)
        self.assertNotEqual(code, 0)
        self.assertIsNotNone(arguments)
        self.assertFalse(cached)

    def test_down_hook_leaves_restoration_to_the_journal(self):
        code, arguments, cached = self.run_hook(phase='dns-down', cache_status=1)
        self.assertEqual(code, 0)
        self.assertIsNone(arguments)
        self.assertFalse(cached)

    def test_unsafe_server_values_still_fail_before_any_operation(self):
        code, arguments, cached = self.run_hook(address='10.8.0.53;exit 0')
        self.assertNotEqual(code, 0)
        self.assertIsNone(arguments)
        self.assertFalse(cached)
