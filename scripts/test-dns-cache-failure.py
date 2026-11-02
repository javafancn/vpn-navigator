#!/usr/bin/env python3
"""Run the production DNS journal's cache-failure regression without root/XCTest."""
from pathlib import Path
import subprocess
import sys
import tempfile

products = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[1]
objects = [products / 'VPNNavigatorCore.o'] if (products / 'VPNNavigatorCore.o').is_file() else sorted((products / 'VPNNavigatorCore.build').glob('*.o'))
assert objects, 'Build VPNNavigatorHelper first'
with tempfile.TemporaryDirectory(prefix='vpnnav-dns-cache-check-') as work:
    folder = Path(work)
    binary = folder / 'dns-cache-checks'
    sources = []
    for name in ['DNSRecoveryJournal.swift', 'DNSJournalSelfTest.swift']:
        source = (root / 'Sources/VPNNavigatorHelper' / name).read_text()
        # Redirect only OS boundary symbols to the in-memory fixture. Journal
        # control flow, serialization, ownership checks and file IO are intact.
        for operation in ['Create', 'CopyValue', 'CopyKeyList', 'SetValue', 'RemoveValue', 'SetMultiple']:
            source = source.replace('SCDynamicStore' + operation + '(', 'FixtureSCDynamicStore' + operation + '(')
        path = folder / name
        path.write_text(source)
        sources.append(str(path))
    subprocess.run(['swiftc', '-DDEBUG', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                    '-I', str(products), '-I', str(products / 'Modules'), *map(str, objects),
                    *sources,
                    str(root / 'scripts/local-tests/DNSCacheFailureRegression.swift'), '-o', str(binary)],
                   check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=15)
