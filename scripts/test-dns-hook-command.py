#!/usr/bin/env python3
"""Real OpenVPN 2.7 parser regression; no VPN, DNS changes, root or user config.

Use a unique missing whitespace prefix. Existing directories on a CI image
must not accidentally make the truncated absolute script filename pass X_OK.
Full installed integration separately exercises actual DNS hook execution.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile


def exercise(engine):
    engine = str(Path(engine).resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix='vpnnav-dns-command-', dir='/tmp') as name:
        root = Path(name)
        directory = root / 'DNS hook files'
        directory.mkdir(mode=0o700)
        hook = directory / 'macos-dns-updown.sh'
        hook.write_text('#!/bin/sh\nexit 0\n')
        hook.chmod(0o700)
        # An incorrectly split argv[0] must not be an accessible directory.
        assert not os.path.lexists(root / 'DNS')

        def check(value, cwd):
            return subprocess.run([engine, '--dns-updown', value, '--show-ciphers'],
                cwd=cwd, text=True, capture_output=True, timeout=15,
                env={**os.environ, 'OPENSSL_CONF': '/dev/null'})

        raw = check(str(hook), root)
        assert raw.returncode == 1 and '--dns-updown script fails' in raw.stderr + raw.stdout, (
            'Pinned engine did not reproduce its raw-path startup validation bug', raw.returncode,
            (raw.stderr + raw.stdout)[-3000:])
        print('PASS: raw spaced DNS hook path reproduces real OpenVPN options exit 1 with a guaranteed missing prefix.')

        quoted = check('"' + str(hook) + '"', root)
        assert quoted.returncode == 0, ('Quoted startup check unexpectedly failed', quoted.stderr[-3000:])
        # Quoting only helps the parser; DNS execution treats quotes as literal
        # filename bytes. Production therefore uses this relative invocation.
        relative = check('./macos-dns-updown.sh', directory)
        assert relative.returncode == 0, ('Relative DNS hook validation failed', relative.stderr[-3000:])
        assert not os.path.lexists(root / 'DNS')
        print('PASS: whitespace-free relative DNS hook passes real engine parsing from a parent containing spaces.')
        print('INFO: installed-prefix directory /Library/Application exists=' + str(os.path.lexists('/Library/Application')))


if __name__ == '__main__':
    exercise(sys.argv[1])
