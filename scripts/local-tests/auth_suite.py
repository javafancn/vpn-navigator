"""Real TLS authentication fixtures, invoked only by test-tls-loopback.py."""
import json
from pathlib import Path
import secrets
import sys


def exercise_auth(folder, profile, ssl, probe, run, start_server, stop_server, config):
    accounts = {}
    events = folder / 'auth-events.jsonl'
    settings = folder / 'auth-settings.json'
    password = secrets.token_hex(20) + ' "quoted" \\ password'
    otp = secrets.token_hex(12) + ' " \\'
    unlock = secrets.token_hex(20)
    wrong = secrets.token_hex(20)
    forbidden = [password, otp, unlock, wrong]
    accounts['plain'] = {'mode': 'plain', 'password': password}
    for flag in range(4):
        accounts['static' + str(flag)] = {'mode': 'static', 'format': 'concat' if flag & 2 else 'scrv1',
                                        'password': password, 'otp': otp}
    for name, count, empty in [('dynamic', 1, False), ('two-rounds', 2, False),
                                ('acknowledge', 1, True), ('too-many', 4, False)]:
        factors = [{'state': secrets.token_hex(20), 'response': '' if empty else secrets.token_hex(12)} for _ in range(count)]
        accounts[name] = {'mode': 'dynamic', 'password': password, 'factors': factors}
        forbidden.extend(item['state'] for item in factors)
        forbidden.extend(item['response'] for item in factors if item['response'])
    settings.write_text(json.dumps({'accounts': accounts, 'events': str(events)}))
    settings.chmod(0o600)
    redactions = folder / 'redactions.json'
    redactions.write_text(json.dumps(forbidden))
    redactions.chmod(0o600)
    passfile = folder / 'key-passphrase'
    passfile.write_text(unlock)
    passfile.chmod(0o600)
    encrypted = folder / 'encrypted-client.key'
    ssl('pkey', '-in', folder / 'client.key', '-aes-256-cbc', '-passout', 'file:' + str(passfile), '-out', encrypted)
    encrypted.chmod(0o600)
    encrypted_profile = profile.replace((folder / 'client.key').read_text(), encrypted.read_text())
    hook = Path(__file__).with_name('verify-auth.py').resolve()
    # OpenVPN parses a command twice: config option, then script argv.
    command = ' '.join(json.dumps(str(path)) for path in [sys.executable, hook, settings])
    stop_server()
    with config.open('a') as output:
        output.write('\nscript-security 2\ntmp-dir ' + str(folder) + '\nauth-user-pass-verify ' + json.dumps(command) + ' via-file\n')
    start_server()

    def exercise(name, username='plain', text=profile, factors=None, outcome='connected', supplied=password,
                 server_event=None, accepted=None):
        path = folder / 'auth-profile.ovpn'
        path.write_text(text + '\nauth-user-pass\n')
        path.chmod(0o600)
        case = folder / 'scenario.json'
        case.write_text(json.dumps({'name': name, 'profilePath': str(path), 'username': username,
                                    'password': supplied, 'outcome': outcome, 'factors': factors or [], 'forbidden': forbidden}))
        case.chmod(0o600)
        before = events.read_text().splitlines() if events.exists() else []
        result = run([probe, '--scenario', case], ok=False, timeout=75)
        print(result.stdout, end='')
        assert result.returncode == 0, 'Authentication scenario failed: ' + name + ' (secrets omitted)'
        after = events.read_text().splitlines() if events.exists() else []
        observed = [json.loads(line) for line in after[len(before):]]
        if server_event:
            assert any(item == {'event': server_event, 'accepted': accepted} for item in observed), 'Server did not independently verify ' + name
        if outcome != 'connected':
            assert not any(item['accepted'] for item in observed), 'Rejected/cancelled case authenticated at server'

    exercise('account password', server_event='plain', accepted=True)
    exercise('wrong account password', supplied=wrong, outcome='failed', server_event='plain', accepted=False)
    exercise('encrypted private key', text=encrypted_profile, factors=[{'kind': 'privateKey', 'response': unlock}], server_event='plain', accepted=True)
    exercise('wrong private key password', text=encrypted_profile, factors=[{'kind': 'privateKey', 'response': wrong}], outcome='failed')
    exercise('cancel private key prompt', text=encrypted_profile, factors=[{'kind': 'privateKey', 'response': ''}], outcome='cancelled')
    for flag in range(4):
        form = 'concat' if flag & 2 else 'scrv1'
        text = profile + '\nstatic-challenge "CI token" ' + str(flag & 1) + ' ' + form + '\n'
        exercise('static flag ' + str(flag), username='static' + str(flag), text=text,
                 factors=[{'kind': 'staticOTP', 'response': otp}], server_event='static-' + form, accepted=True)
    static = profile + '\nstatic-challenge "CI token" 0\n'
    exercise('wrong static OTP', username='static0', text=static, factors=[{'kind': 'staticOTP', 'response': wrong}],
             outcome='failed', server_event='static-scrv1', accepted=False)
    exercise('cancel static OTP', username='static0', text=static, factors=[{'kind': 'staticOTP', 'response': ''}], outcome='cancelled')
    for name in ['dynamic', 'two-rounds', 'acknowledge']:
        factors = [{'kind': 'dynamicOTP', 'response': item['response']} for item in accounts[name]['factors']]
        exercise(name, username=name, factors=factors, server_event='dynamic-complete', accepted=True)
    exercise('wrong dynamic OTP', username='dynamic', factors=[{'kind': 'dynamicOTP', 'response': wrong}],
             outcome='failed', server_event='rejected', accepted=False)
    exercise('cancel dynamic OTP', username='dynamic', factors=[{'kind': 'dynamicOTP', 'response': ''}], outcome='cancelled')
    factors = [{'kind': 'dynamicOTP', 'response': item['response']} for item in accounts['too-many']['factors'][:3]]
    exercise('fourth CRV1 factor refused', username='too-many', factors=factors,
             outcome='failed', server_event='dynamic-challenge-3', accepted=False)
    # A real transport interruption must expose failure, clean up and reconnect.
    # Use the certificate-only server for transport loss, independently of auth.
    stop_server()
    original_config = config.read_text().split('\nscript-security 2\n', 1)[0]
    config.write_text(original_config)
    start_server()
    run([probe, '--connect-only', folder / 'valid.ovpn'])
    stop_server()
    run([probe, '--expect-failed'])
    start_server()
    run([probe, folder / 'valid.ovpn', folder / 'wrong-ca.ovpn'], timeout=120)
    print('PASS: real server transport loss, visible failed state, cleanup and reconnect.')
