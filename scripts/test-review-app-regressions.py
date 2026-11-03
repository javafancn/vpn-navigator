#!/usr/bin/env python3
"""Compile real app control flow with disposable XPC/network boundaries; no UI/root."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
products = Path(sys.argv[1]).resolve()
objects = [products / 'VPNNavigatorCore.o'] if (products / 'VPNNavigatorCore.o').is_file() else sorted((products / 'VPNNavigatorCore.build').glob('*.o'))
assert objects, 'Build VPNNavigatorHelper first'


def section(source, first, last):
    return source[source.index(first):source.index(last, source.index(first))]


with tempfile.TemporaryDirectory(prefix='vpnnav-app-review-') as directory:
    work = Path(directory)
    transport = (ROOT / 'Sources/VPNNavigatorApp/HelperTransport.swift').read_text()
    transport = transport.replace('NSXPCConnection', 'FixtureXPCConnection').replace('VPNNavigatorHelperAPI', 'FixtureHelperAPI')
    client = (ROOT / 'Sources/VPNNavigatorApp/HelperClient.swift').read_text()
    report = section(client, '    func sessionReport(', '    func activeProfile(')
    fixture = (ROOT / 'scripts/local-tests/HelperIdleLifetimeRegression.swift').read_text().replace('// SESSION_REPORT', report)
    (work / 'HelperTransport.swift').write_text(transport)
    (work / 'HelperIdleLifetimeRegression.swift').write_text(fixture)
    binary = work / 'helper-idle'
    common = ['swiftc', '-parse-as-library', '-module-cache-path', str(work / 'modules'),
              '-I', str(products), '-I', str(products / 'Modules'), *map(str, objects)]
    subprocess.run([*common, str(work / 'HelperTransport.swift'), str(work / 'HelperIdleLifetimeRegression.swift'), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=45)

    smart = (ROOT / 'Sources/VPNNavigatorApp/SmartConnectionController.swift').read_text()
    methods = section(smart, '    private func refreshNetwork()', '    nonisolated private static func readNetwork(')
    methods += section(smart, '    private func applyNetwork(', '    func observe(')
    methods += next(line for line in smart.splitlines() if 'func cancelPending()' in line) + '\n'
    permit = section(smart, '                await model.connectSelected(automatically: true, automationPermit: { [weak self] in', '\n                })')
    permit = permit[permit.index('\n') + 1:]
    fixture = (ROOT / 'scripts/local-tests/SmartConnectionRaceRegression.swift').read_text()
    fixture = fixture.replace('// PRODUCTION_METHODS', methods).replace('// AUTOMATION_PERMIT', permit)
    app = (ROOT / 'Sources/VPNNavigatorApp/VPNNavigatorApp.swift').read_text()
    start = app.index('    func connectSelected(')
    end = app.find('\n    func ', start + 1)
    connect = app[start:end if end >= 0 else len(app)]
    assert 'automationPermit: (() async -> Bool)?' in connect and connect.count('guard await automationPermit?() == true') == 3, 'Every permission boundary must await the fresh snapshot'
    (work / 'SmartConnectionRaceRegression.swift').write_text(fixture)
    binary = work / 'smart-races'
    subprocess.run([*common, str(work / 'SmartConnectionRaceRegression.swift'), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=20)
