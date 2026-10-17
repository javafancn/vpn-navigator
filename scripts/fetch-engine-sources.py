#!/usr/bin/env python3
"""Build-machine only: fetch source archives pinned by Homebrew formula SHA256.

Signed releases additionally compare these against maintainer-supplied hashes.
No binary or signing secret is downloaded or created by this helper.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import urllib.request
import urllib.parse


def main():
    destination = pathlib.Path(sys.argv[1]).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output(["brew", "info", "--json=v2", "openvpn", "openssl@3"], text=True))
    output = {}
    for formula in metadata["formulae"]:
        name = formula["name"]
        key = "OPENVPN" if name == "openvpn" else "OPENSSL"
        source = formula["urls"]["stable"]
        url, expected = source["url"], source["checksum"]
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https" or parsed.hostname not in {"swupdate.openvpn.org", "github.com", "www.openssl.org", "openssl-library.org"}:
            raise SystemExit("Formula source does not use an approved upstream HTTPS host")
        path = destination / (key.lower() + "-source.tar.gz")
        digest = hashlib.sha256()
        count = 0
        with urllib.request.urlopen(url, timeout=30) as response, path.open("wb") as target:
            while chunk := response.read(128 * 1024):
                count += len(chunk)
                if count > 100_000_000:
                    raise SystemExit("Source archive exceeds size limit")
                target.write(chunk)
                digest.update(chunk)
        if digest.hexdigest().lower() != expected.lower():
            raise SystemExit("Upstream archive does not match formula SHA256")
        output[key + "_SOURCE_ARCHIVE"] = str(path)
        output[key + "_SOURCE_SHA256"] = digest.hexdigest()
        output[key + "_SOURCE_VERSION"] = formula["versions"]["stable"]
    if len(output) != 6:
        raise SystemExit("Both OpenVPN and OpenSSL source archives are required")
    (destination / "sources.json").write_text(json.dumps(output, indent=2) + "\n")
    if os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a") as environment:
            for key, value in output.items():
                if "\n" in value or "\r" in value:
                    raise SystemExit("Invalid source metadata")
                environment.write(key + "=" + value + "\n")
    print(json.dumps({key: value for key, value in output.items() if key.endswith(("SHA256", "VERSION"))}, indent=2))


if __name__ == "__main__":
    main()
