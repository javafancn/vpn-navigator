"""Real application Quit on disposable installed-system CI Macs only."""
import os
from pathlib import Path
import re
import time

APP = Path('/Applications/VPN Navigator.app/Contents/MacOS/VPNNavigatorApp')
BASE = Path('/Library/Application Support/VPNNavigator/Local')
LABEL = 'system/com.javafancn.vpn-navigator.local-helper'


def helper_pid(run):
    result = run(['launchctl', 'print', LABEL])
    match = re.search(r'^\s*pid = (\d+)\s*$', result.stdout, re.MULTILINE)
    return int(match.group(1)) if match else None


def exercise_quit(run, active=False, recovering=False, cleanup_timeout=40):
    assert os.environ.get('GITHUB_ACTIONS') == 'true'
    before = (BASE / 'manifest.json').read_bytes()
    plist = Path('/Library/LaunchDaemons/com.javafancn.vpn-navigator.local-helper.plist')
    registered = plist.read_bytes()
    pid = helper_pid(run)
    assert pid is not None, 'Fixture must start with a live authenticated helper'
    if active:
        run([APP, '--vpnnav-local-traffic-self-test'])
        run([APP, '--vpnnav-local-quit-rejection-check'])
        assert helper_pid(run) == pid, 'Unsafe exit killed the active helper'
    arguments = ['env', 'VPNNAV_UI_SELF_TEST_TIMEOUT=' + str(cleanup_timeout), 'python3', 'scripts/run-ui-self-test.py', APP, '--vpnnav-quit-process-self-test']
    if recovering:
        arguments.append('--vpnnav-quit-with-recoverable-journal')
    result = run(arguments, timeout=max(120, cleanup_timeout + 30))
    assert 'Quit fixture: real application termination requested' in result.stdout
    # launchctl print and signal zero do not wake the Mach service.
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        except PermissionError:
            pass
        time.sleep(.1)
    else:
        raise AssertionError('Application exited while its root helper remained alive')
    time.sleep(5)
    assert helper_pid(run) is None, 'A poll or scheduled agent restarted the helper after Quit'
    assert (BASE / 'manifest.json').read_bytes() == before
    assert plist.read_bytes() == registered
    assert not (BASE / 'retired-approval.json').exists(), 'Normal Quit must not revoke approval'
    assert not (BASE / 'install-state.json').exists()
    for name in ['active.ovpn', 'openvpn-child.json', 'routes.journal', 'dns.journal', 'pf-guard.json']:
        assert not Path('/var/run/vpn-navigator', name).exists(), 'Quit left unresolved network evidence: ' + name
    run([APP, '--vpnnav-local-health-check'])
    assert helper_pid(run) not in (None, pid), 'Next demand did not launch a new authenticated helper'
    assert (BASE / 'manifest.json').read_bytes() == before
    print('PASS: real application Quit ' + ('disconnects TLS VPN, restores network and ' if active else '') +
          'ends helper process, remains stopped, preserves approval and registration, and relaunches on next demand.')
    if recovering:
        print('PASS: real application Quit safely reconciles an absent pending route intent and completes network recovery before stopping the helper.')
