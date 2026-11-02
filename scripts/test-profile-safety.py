#!/usr/bin/env python3
"""Run identity and real multi-process repository checks without XCTest.

Usage: python3 scripts/test-profile-safety.py <Swift build Products/Release directory>
The directory must contain VPNNavigatorCore.o and its Swift module.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

products = Path(sys.argv[1]).resolve()
objects = [products / 'VPNNavigatorCore.o'] if (products / 'VPNNavigatorCore.o').is_file() else sorted((products / 'VPNNavigatorCore.build').glob('*.o'))
assert objects, 'Build VPNNavigatorHelper first'
source = Path(__file__).resolve().parent / 'local-tests' / 'ProfileSafetyRegression.swift'
certificate = source.parents[1].parent / 'Sources' / 'VPNNavigatorCoreTests' / 'HealthCertificateFixture.swift'
with tempfile.TemporaryDirectory(prefix='vpnnav-profile-checks-') as work:
    folder = Path(work)
    binary = folder / 'profile-checks'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                    '-I', str(products), '-I', str(products / 'Modules'),
                    *map(str, objects), str(source), str(certificate), '-o', str(binary)],
                   check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=120)
