#!/usr/bin/env python3
"""Relocate a vetted macOS OpenVPN executable into VPN Navigator.app.

Build-machine-only tool: collects non-Apple dynamic libraries recursively and
rewrites Mach-O load commands. Rejects unresolved @rpath references and basename
collisions instead of producing an apparently portable but broken installer.
All binaries are re-signed by build-app.sh after modification.
"""
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

def dependencies(binary):
    lines = command("/usr/bin/otool", "-L", str(binary)).splitlines()[1:]
    result = []
    for line in lines:
        raw = line.strip().split(" (compatibility version", 1)[0].split(" (current version", 1)[0].strip()
        if raw:
            result.append(raw)
    return result

def is_system(dep):
    return dep.startswith("/usr/lib/") or dep.startswith("/System/Library/")

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(128 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: vendor-openvpn.py OPENVPN_BINARY 'VPN Navigator.app'")
    source = Path(sys.argv[1]).resolve(strict=True)
    app = Path(sys.argv[2]).resolve(strict=True)
    resource_dir = app / "Contents" / "Resources"
    frameworks = app / "Contents" / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    dest = resource_dir / "openvpn"
    if not source.is_file():
        raise RuntimeError("OpenVPN binary missing")
    shutil.copy2(source, dest)

    pending = [(source, dest)]
    seen = {}
    manifest = []
    while pending:
        original, installed = pending.pop(0)
        seen[str(original)] = str(installed)
        for dep in dependencies(original):
            if dep == str(original) or (dep.startswith("@") and Path(dep).name == original.name):
                continue
            if is_system(dep):
                continue
            if dep.startswith("@"):
                raise RuntimeError(f"Unresolved Mach-O load path {dep!r} in {original}")
            dependency = Path(dep).resolve(strict=True)
            dest_lib = frameworks / dependency.name
            if dest_lib.exists():
                if digest(dependency) != digest(dest_lib):
                    raise RuntimeError(f"Conflicting dylibs with name {dependency.name}: {dependency}")
            else:
                shutil.copy2(dependency, dest_lib)
            if str(dependency) not in seen and all(pair[0] != dependency for pair in pending):
                pending.append((dependency, dest_lib))
            prefix = "@executable_path/../Frameworks" if installed == dest else "@loader_path"
            replacement = f"{prefix}/{dependency.name}"
            command("/usr/bin/install_name_tool", "-change", dep, replacement, str(installed))
        if installed != dest:
            command("/usr/bin/install_name_tool", "-id", "@loader_path/" + installed.name, str(installed))
        manifest.append({
            "source": str(original),
            "bundle_path": str(installed.relative_to(app)),
            "source_sha256": digest(original)
        })

    # Verify that no build-machine dylib paths remain after relocation.
    for entry in [dest, *sorted(frameworks.glob("*.dylib"))]:
        for dep in dependencies(entry):
            if dep == "@loader_path/" + entry.name:
                continue
            if is_system(dep):
                continue
            if dep.startswith("@executable_path/../Frameworks/") or dep.startswith("@loader_path/"):
                basename = Path(dep).name
                if not (frameworks / basename).is_file():
                    raise RuntimeError(f"Missing relocated dependency: {dep}")
                continue
            raise RuntimeError(f"Unresolved external dependency in {entry}: {dep}")
    (resource_dir / "openvpn-dependencies.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    command(str(dest), "--version")
    print(f"Relocated OpenVPN plus {len(manifest)-1} libraries into {app}")

if __name__ == "__main__":
    main()
