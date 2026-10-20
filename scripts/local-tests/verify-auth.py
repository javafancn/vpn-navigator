#!/usr/bin/env python3
"""Synthetic loopback server hook, never installed or enabled by the product."""
import base64
import json
import os
from pathlib import Path
import sys


def verify(settings, username, password):
    account = settings['accounts'].get(username)
    if account is None:
        return False, 'unknown-account', None
    mode = account['mode']
    if mode == 'plain':
        return password == account['password'], 'plain', None
    if mode == 'static':
        if account['format'] == 'concat':
            expected = account['password'] + account['otp']
        else:
            expected = 'SCRV1:' + base64.b64encode(account['password'].encode()).decode() + ':' + base64.b64encode(account['otp'].encode()).decode()
        return password == expected, 'static-' + account['format'], None
    if mode == 'dynamic':
        factors = account['factors']
        next_factor = 0 if password == account['password'] else None
        for index, factor in enumerate(factors):
            if password == 'CRV1::' + factor['state'] + '::' + factor['response']:
                next_factor = index + 1
                break
        if next_factor == len(factors):
            return True, 'dynamic-complete', None
        if next_factor is not None:
            factor = factors[next_factor]
            flags = 'R' if factor['response'] else ''
            reason = 'CRV1:' + flags + ':' + factor['state'] + ':' + base64.b64encode(username.encode()).decode() + ':CI factor'
            return False, 'dynamic-challenge-' + str(next_factor), reason
    return False, 'rejected', None


def main():
    assert sys.platform == 'darwin' and os.getuid() == 0
    settings = json.loads(Path(sys.argv[1]).read_text())
    username, password = Path(sys.argv[2]).read_text().splitlines()[:2]
    accepted, event, reason = verify(settings, username, password)
    # Record only enum outcomes. Never persist credentials, responses or state.
    with Path(settings['events']).open('a') as output:
        output.write(json.dumps({'event': event, 'accepted': accepted}) + '\n')
    if reason:
        Path(os.environ['auth_failed_reason_file']).write_text(reason)
    return 0 if accepted else 1


if __name__ == '__main__':
    sys.exit(main())
