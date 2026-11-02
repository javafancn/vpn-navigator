import http.server
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location('managed_web', Path(__file__).parents[1] / 'local-tests/managed_web.py')
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)


@unittest.skipUnless(shutil.which('openssl') and shutil.which('curl'), 'OpenSSL and curl fixture tools')
class ManagedWebTests(unittest.TestCase):
    def test_https_fixture_verifies_certificate_and_exposes_tls_timing(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Length', '4')
                self.end_headers()
                self.wfile.write(b'test')

            def log_message(self, *args):
                pass

        with tempfile.TemporaryDirectory(prefix='vpnnav-web-test-') as directory:
            folder = Path(directory)
            config = folder / 'certificate.cnf'
            config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n'
                              '[dn]\nCN=localhost\n[extensions]\nsubjectAltName=DNS:localhost\n'
                              'basicConstraints=critical,CA:TRUE\nkeyUsage=digitalSignature,keyEncipherment,keyCertSign\n'
                              'extendedKeyUsage=serverAuth\n')
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-config', str(config), '-keyout', str(folder / 'web.key'), '-out', str(folder / 'web.crt')],
                           check=True, capture_output=True, timeout=30)
            server = web.https_server(folder, Handler, address=('127.0.0.1', 0))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                command = ['curl', '--noproxy', '*', '--ipv4', '--fail', '--silent', '--show-error', '--max-time', '3',
                           '--cacert', str(folder / 'web.crt'), '--write-out', '\n%{json}',
                           f'https://localhost:{server.server_address[1]}/']
                result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=5)
                body, metrics = result.stdout.rsplit('\n', 1)
                self.assertEqual(body, 'test')
                timing = json.loads(metrics)
                self.assertGreater(timing['time_appconnect'], 0)
                self.assertGreaterEqual(timing['time_total'], timing['time_appconnect'])
                # Without the synthetic trust anchor, verification must fail.
                untrusted = command.copy()
                index = untrusted.index('--cacert')
                del untrusted[index:index+2]
                rejected = subprocess.run(untrusted, capture_output=True, text=True, timeout=5)
                self.assertNotEqual(rejected.returncode, 0)
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=3)
