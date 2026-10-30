#!/usr/bin/env python3
"""Audit packaged Mach-O architecture/minimum OS and write a sidecar manifest."""
import hashlib
import json
import pathlib
import platform
import plistlib
import re
import subprocess
import sys


def minimum_versions(path):
    output = subprocess.check_output(["otool", "-l", str(path)], text=True)
    versions, command = [], None
    for line in output.splitlines():
        fields = line.split()
        if fields[:1] == ["cmd"]:
            command = fields[1] if len(fields) == 2 else None
        if len(fields) == 2 and ((command == "LC_BUILD_VERSION" and fields[0] == "minos") or
                                 (command == "LC_VERSION_MIN_MACOSX" and fields[0] == "version")):
            versions.append(fields[1])
    if not versions:
        raise RuntimeError(f"Missing macOS deployment metadata: {path.name}")
    return versions


def version(value):
    return tuple(int(part) for part in value.split(".")) + (0,) * (3 - len(value.split(".")))


def main():
    app, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    minimum = info["LSMinimumSystemVersion"]
    architecture = platform.machine()
    entries = [app / "Contents/MacOS/VPNNavigatorApp"]
    entries += [app / "Contents/Resources" / name for name in ("VPNNavigatorHelper", "VPNNavigatorRuleAgent", "openvpn")]
    setup = app / "Contents/Resources/VPNNavigatorLocalSetup"
    if setup.exists():
        entries.append(setup)
    entries += sorted((app / "Contents/Frameworks").glob("*.dylib"))
    binaries = []
    for path in entries:
        archs = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
        if architecture not in archs:
            raise RuntimeError(f"{path.name} lacks architecture {architecture}")
        versions = minimum_versions(path)
        if any(version(value) > version(minimum) for value in versions):
            raise RuntimeError(f"{path.name} requires macOS {versions}, above app minimum {minimum}; build a compatible engine")
        binaries.append({"path": str(path.relative_to(app)), "architectures": archs, "minimum_macos": versions,
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    domains = app / "Contents/Resources/china-dns-domains.txt"
    source = pathlib.Path(__file__).resolve().parents[1] / "Sources/VPNNavigatorHelper/ChinaDNSRules.swift"
    expected = re.search(r'static let sha256 = "([0-9a-f]{64})"', source.read_text())[1]
    domain_bytes = domains.read_bytes()
    if domains.is_symlink() or len(domain_bytes) > 4_000_000 or hashlib.sha256(domain_bytes).hexdigest() != expected:
        raise RuntimeError("Bundled DNS domains do not match the helper's pinned snapshot")
    if not (app / "Contents/Resources/LICENSES/DNSMASQ_CHINA_LIST_NOTICE.txt").is_file():
        raise RuntimeError("DNS domain attribution is missing")
    source_files = sorted((app / "Contents/Resources/Sources").glob("*.tar.gz"))
    manifest = {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                "architecture": architecture, "minimum_macos": minimum, "build_channel": info.get("VPNNavigatorBuildChannel", "legacy"), "binaries": binaries,
                "dns_domains": {"sha256": expected, "entries": len(domain_bytes.splitlines())},
                "sources": [{"name": p.name, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in source_files]}
    output.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Architecture and minimum macOS verified: {architecture}, {minimum}")


if __name__ == "__main__":
    main()
