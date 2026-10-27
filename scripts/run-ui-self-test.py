#!/usr/bin/env python3
"""Run a native UI check with bounded stack diagnostics on a hang."""
import subprocess
import sys

# AppKit's documented automated-test option redirects restorable state into a
# temporary directory. A previous close/reopen fixture must not decide whether
# the next process gets a main window. The application's normal launch settings
# are not modified: this applies only to this test process's argument domain.
command = [sys.argv[1], '-ApplePersistenceIgnoreState', 'YES', *sys.argv[2:]]
process = subprocess.Popen(command)
try:
    raise SystemExit(process.wait(timeout=40))
except subprocess.TimeoutExpired:
    print('UI self-test timed out; collecting native stacks', flush=True)
    subprocess.run(['/usr/bin/sample', str(process.pid), '2', '1'], timeout=10, check=False)
    process.kill()
    process.wait(timeout=5)
    raise SystemExit(1)
