"""Execute installer control flow against isolated jobs/files, never launchd."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class IdleHelperMaintenanceTests(unittest.TestCase):
    def run_package(self, kind, *, running='', evidence=False, stuck=False, late_evidence=False):
        with tempfile.TemporaryDirectory(prefix='vpnnav-maintenance-') as work:
            folder = Path(work)
            base = folder / 'Local'
            runtime = folder / 'runtime'
            base.joinpath('Payload').mkdir(parents=True)
            runtime.mkdir()
            script = ROOT / ('scripts/local-pkg-scripts/preinstall' if kind == 'install' else 'scripts/local-uninstall-scripts/postinstall')
            source = script.read_text().replace('/Library/Application Support/VPNNavigator/Local', str(base)).replace('/var/run/vpn-navigator', str(runtime))
            (folder / 'guard').write_text('check_local_paths() { return 0; }\ncheck_local_setup() { return 0; }\n')
            (folder / 'architecture').write_text(os.uname().machine)
            (folder / 'version').write_text('0.8.14')
            setup = base / 'Payload/VPNNavigatorLocalSetup'
            setup.write_text('#!/bin/bash\ntouch "$FIXTURE/setup-called"\n')
            setup.chmod(0o700)
            launchctl = folder / 'launchctl'
            launchctl.write_text('''#!/bin/bash
if [[ "$1" == bootout ]]; then
  touch "$FIXTURE/bootout-called"
  [[ "$STUCK" == 1 ]] || touch "$FIXTURE/stopped"
  [[ "$LATE" == 1 ]] && touch "$FIXTURE/runtime/routes.journal"
  exit 0
fi
[[ "$2" == system/com.javafancn.vpn-navigator.local-helper && ! -e "$FIXTURE/stopped" ]]
''')
            pgrep = folder / 'pgrep'
            pgrep.write_text('''#!/bin/bash
[[ "$2" == "$RUNNING" ]] && exit 0
[[ "$2" == VPNNavigatorHelper && ! -e "$FIXTURE/stopped" ]]
''')
            install = folder / 'install'
            install.write_text('#!/bin/bash\nmkdir -p "${@: -2:1}" "${@: -1}"\n')
            for command in [launchctl, pgrep, install]:
                command.chmod(0o700)
            source = source.replace('/bin/launchctl', str(launchctl)).replace('/usr/bin/pgrep', str(pgrep)).replace('/usr/bin/install', str(install)).replace('/bin/sleep 0.1', ':').replace('/bin/sync', ':')
            package = folder / 'package-script'
            package.write_text(source)
            if evidence:
                (runtime / 'routes.journal').touch()
            result = subprocess.run(['/bin/bash', str(package), '', '', '/'], capture_output=True, text=True,
                                    env={**os.environ, 'FIXTURE': str(folder), 'RUNNING': running, 'STUCK': str(int(stuck)), 'LATE': str(int(late_evidence))}, timeout=5)
            return result.returncode, (folder / 'bootout-called').exists(), (folder / 'setup-called').exists(), (base / 'install-state.json').exists()

    def test_idle_startup_helper_can_be_stopped_for_install_and_uninstall(self):
        for kind in ['install', 'uninstall']:
            with self.subTest(kind=kind):
                code, stopped, setup, transaction = self.run_package(kind)
                self.assertEqual(code, 0)
                self.assertTrue(stopped)
                self.assertEqual(setup, kind == 'uninstall')
                self.assertEqual(transaction, kind == 'install')

    def test_active_network_evidence_refuses_before_stopping_service(self):
        for kind in ['install', 'uninstall']:
            with self.subTest(kind=kind):
                code, stopped, setup, transaction = self.run_package(kind, evidence=True)
                self.assertNotEqual(code, 0)
                self.assertFalse(stopped or setup or transaction)

    def test_live_application_still_blocks_replacement(self):
        for kind in ['install', 'uninstall']:
            code, stopped, setup, transaction = self.run_package(kind, running='VPNNavigatorApp')
            self.assertNotEqual(code, 0)
            self.assertFalse(stopped or setup or transaction)

    def test_unstopped_helper_and_late_journal_block_payload_changes(self):
        for kind in ['install', 'uninstall']:
            for options in [{'stuck': True}, {'late_evidence': True}]:
                with self.subTest(kind=kind, options=options):
                    code, stopped, setup, transaction = self.run_package(kind, **options)
                    self.assertNotEqual(code, 0)
                    self.assertTrue(stopped)
                    self.assertFalse(setup or transaction)
