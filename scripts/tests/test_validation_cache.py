from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin file metadata')
class ValidationCacheTests(unittest.TestCase):
    def test_production_cache_invalidates_changed_inputs(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix='vpnnav-cache-regression-') as work:
            folder = Path(work)
            binary = folder / 'cache-checks'
            subprocess.run(['swiftc', '-O', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                            str(root / 'Sources/VPNNavigatorCore/ValidatedFileCache.swift'),
                            str(root / 'scripts/local-tests/ValidationCacheRegression.swift'), '-o', str(binary)],
                           check=True, capture_output=True, text=True, timeout=90)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=15)
            self.assertIn('PASS:', result.stdout)
