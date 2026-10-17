#!/usr/bin/env python3
"""Build-machine only: fetch source archives pinned by reviewed upstream release SHA256.

Signed releases additionally compare these against maintainer-supplied hashes.
No binary or signing secret is downloaded or created by this helper.
"""
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.request
import urllib.error
import urllib.parse


def main():
    destination = pathlib.Path(sys.argv[1]).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    metadata = json.loads((pathlib.Path(__file__).resolve().parents[1] / "Resources/Engine/sources.lock.json").read_text())
    output = {}
    for name in ("openvpn", "openssl"):
        source = metadata[name]
        key = "OPENVPN" if name == "openvpn" else "OPENSSL"
        url, expected = source["url"], source["sha256"]
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise SystemExit("Invalid pinned source SHA256")
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https" or parsed.hostname not in {"swupdate.openvpn.org", "swupdate.openvpn.net", "build.openvpn.net", "github.com", "www.openssl.org", "openssl-library.org"}:
            raise SystemExit("Pinned source does not use an approved upstream HTTPS host")
        path = destination / (key.lower() + "-source.tar.gz")
        candidates = [url]
        version = source["version"]
        if key == "OPENVPN" and re.fullmatch(r"2\.7\.[0-9]+", version):
            # Official release assets have the same reviewed archive digest.
            # GitHub runners may receive a CDN/WAF 403 from swupdate.openvpn.net.
            candidates.insert(0, f"https://github.com/OpenVPN/openvpn/releases/download/v{version}/openvpn-{version}.tar.gz")
            candidates.append(f"https://build.openvpn.net/downloads/releases/openvpn-{version}.tar.gz")
        for candidate in dict.fromkeys(candidates):
            digest = hashlib.sha256()
            count = 0
            try:
                request = urllib.request.Request(candidate, headers={"User-Agent": "VPNNavigator-SourceBuilder/0.2"})
                print(f"Fetching {key} source from {urllib.parse.urlparse(candidate).hostname}", flush=True)
                with urllib.request.urlopen(request, timeout=30) as response, path.open("wb") as target:
                    while chunk := response.read(128 * 1024):
                        count += len(chunk)
                        if count > 100_000_000:
                            raise SystemExit("Source archive exceeds size limit")
                        target.write(chunk)
                        digest.update(chunk)
            except (urllib.error.URLError, TimeoutError):
                path.unlink(missing_ok=True)
                continue
            if digest.hexdigest().lower() != expected.lower():
                raise SystemExit("Upstream archive does not match reviewed SHA256")
            break
        else:
            raise SystemExit(f"Unable to fetch verified {key} sources from official upstreams")
        output[key + "_SOURCE_ARCHIVE"] = str(path)
        output[key + "_SOURCE_SHA256"] = digest.hexdigest()
        output[key + "_SOURCE_VERSION"] = version
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
