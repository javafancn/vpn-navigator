#!/usr/bin/env python3
"""Run a native UI check with bounded stack diagnostics on a hang."""
import subprocess
import sys

process = subprocess.Popen(sys.argv[1:])
try:
    raise SystemExit(process.wait(timeout=40))
except subprocess.TimeoutExpired:
    print('UI self-test timed out; collecting native stacks', flush=True)
    subprocess.run(['/usr/bin/sample', str(process.pid), '2', '1'], timeout=10, check=False)
    process.kill()
    process.wait(timeout=5)
    raise SystemExit(1)
