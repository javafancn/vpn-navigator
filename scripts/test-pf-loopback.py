#!/usr/bin/env python3
"""Disposable macOS CI only. Test one loopback port, then restore root rules.

No production controller writes root rules. This fixture adds the stock root
anchor only if the runner started with an empty filter ruleset. It never loads
the application's global egress block or touches external connections.
"""
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading


def pf(*args):
    return subprocess.run(["sudo", "/sbin/pfctl", *args], text=True, capture_output=True, check=True).stdout.strip()


def main():
    helper = str(pathlib.Path(sys.argv[1]).resolve())
    root = pf("-sr")
    initialized = not root
    filters = [line for line in root.splitlines() if line != 'scrub-anchor "com.apple/*" all fragment reassemble']
    if root and filters not in (['anchor "com.apple/*" all'], ['anchor "com.apple/*"']):
        raise SystemExit(f"Runner PF root rules need inspection; fixture refuses to alter them: {root!r}")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    listener.settimeout(0.5)
    port = listener.getsockname()[1]
    stopping = threading.Event()

    def accept():
        while not stopping.is_set():
            try:
                client, _ = listener.accept()
                client.close()
            except socket.timeout:
                pass
            except OSError:
                break

    threading.Thread(target=accept, daemon=True).start()

    def reachable():
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            return False

    with tempfile.TemporaryDirectory() as folder:
        fixture = pathlib.Path(folder) / "root.conf"
        fixture.write_text('anchor "com.apple/*"\n')
        original = pathlib.Path(folder) / "original.conf"
        original.write_text(root + "\n")
        try:
            if initialized:
                pf("-R", "-f", str(fixture))
            assert reachable(), "Loopback listener unavailable before test"
            subprocess.run(["sudo", helper, "--self-test-pf-install", str(port)], check=True, timeout=25)
            assert not reachable(), "Kernel PF did not block the selected loopback port"
            subprocess.run(["sudo", helper, "--self-test-pf-release"], check=True, timeout=25)
            assert reachable(), "Loopback connectivity did not recover"
            print("PASS: actual kernel PF anchor activation, blocking, token release and recovery.")
        finally:
            subprocess.run(["sudo", helper, "--self-test-pf-release"], timeout=25, check=False)
            if initialized:
                pf("-R", "-f", str(original))
            stopping.set()
            listener.close()


if __name__ == "__main__":
    main()
