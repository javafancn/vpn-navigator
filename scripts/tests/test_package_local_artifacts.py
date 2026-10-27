import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package_artifacts', Path(__file__).parents[1] / 'package-local-artifacts.py')
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


class InstallerArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        self.output = self.root / 'download'
        self.prefix = 'VPN-Navigator-0.8.0-arm64-Local'
        self.installer = self.dist / (self.prefix + '.pkg')
        self.uninstaller = self.dist / (self.prefix + '-Uninstall.pkg')
        self.installer.write_bytes(b'fixture installer bytes')
        self.uninstaller.write_bytes(b'fixture uninstall bytes')
        self.audit = {'version': '0.8.0', 'build': '20', 'architecture': 'arm64',
                      'build_channel': 'local-test', 'minimum_macos': '13.0',
                      'sources': [{'name': n} for n in ['OpenVPN-source.tar.gz', 'OpenSSL-source.tar.gz']], 'binaries': []}
        self.manifest = {'version': '0.8.0', 'architecture': 'arm64', 'schema': 1,
                         'uninstallerSHA256': artifacts.digest(self.uninstaller), 'binaries': {}}
        for key, (path, identifier) in artifacts.BINARIES.items():
            digest = hashlib.sha256(key.encode()).hexdigest()
            self.audit['binaries'].append({'path': path, 'architectures': ['arm64'], 'minimum_macos': ['13.0'], 'sha256': digest})
            self.manifest['binaries'][key] = {'identifier': identifier, 'sha256': digest, 'cdhash': 'a' * 40}
        (self.dist / (self.prefix + '-SHA256.txt')).write_text(''.join(artifacts.digest(p) + '  ' + p.name + '\n' for p in [self.installer, self.uninstaller]))

    def run_stage(self):
        (self.dist / 'VPN-Navigator-arm64-Local-audit.json').write_text(json.dumps(self.audit))
        (self.dist / (self.prefix + '-manifest.json')).write_text(json.dumps(self.manifest))
        return artifacts.stage(self.dist, 'arm64', self.output, '1' * 40, 'https://github.com/javafancn/vpn-navigator/actions/runs/123')

    def test_complete_download_preserves_pkg_bytes_and_records_source(self):
        result = self.run_stage()
        self.assertEqual((self.output / self.installer.name).read_bytes(), self.installer.read_bytes())
        self.assertEqual((self.output / self.uninstaller.name).read_bytes(), self.uninstaller.read_bytes())
        self.assertEqual(result['source_commit'], '1' * 40)
        self.assertEqual(len(list(self.output.iterdir())), 7)

    def test_tampered_installer_is_not_staged(self):
        self.installer.write_bytes(b'changed after packaging')
        with self.assertRaisesRegex(ValueError, 'PKG checksum'): self.run_stage()
        self.assertFalse(self.output.exists())

    def test_wrong_architecture_and_minimum_os_are_rejected(self):
        for field, value in [('architectures', ['x86_64']), ('minimum_macos', ['14.0'])]:
            with self.subTest(field=field):
                item = self.audit['binaries'][0]
                old = item[field]; item[field] = value
                with self.assertRaises(ValueError): self.run_stage()
                item[field] = old

    def test_preview_or_missing_engine_cannot_be_called_complete(self):
        self.audit['build_channel'] = 'preview'
        with self.assertRaises(ValueError): self.run_stage()
        self.audit['build_channel'] = 'local-test'
        self.audit['binaries'] = [b for b in self.audit['binaries'] if b['path'] != artifacts.BINARIES['engine'][0]]
        with self.assertRaisesRegex(ValueError, 'engine'): self.run_stage()

    def test_manifest_from_another_build_is_rejected(self):
        self.manifest['binaries']['helper']['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'identity mismatch'): self.run_stage()

    def test_checksum_traversal_and_duplicate_entries_are_rejected(self):
        checksums = self.dist / (self.prefix + '-SHA256.txt')
        for text in ['a' * 64 + '  ../outside.pkg\n', checksums.read_text() * 2]:
            checksums.write_text(text)
            with self.assertRaisesRegex(ValueError, 'checksum entry'): self.run_stage()

    def test_existing_download_is_preserved(self):
        self.output.mkdir(); original = self.output / 'keep.txt'; original.write_text('keep')
        with self.assertRaisesRegex(ValueError, 'fresh empty'): self.run_stage()
        self.assertEqual(original.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
