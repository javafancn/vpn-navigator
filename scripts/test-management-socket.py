#!/usr/bin/env python3
"""Real Unix socket fixtures: never root, no OpenVPN process or network changes."""
import base64
import pathlib
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time


def exercise(helper, scenario):
    errors = queue.Queue()
    with tempfile.TemporaryDirectory(prefix="vpnnav-mgt-", dir="/tmp") as folder:
        path = str(pathlib.Path(folder) / "management.sock")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(9)

            def server():
                try:
                    with listener.accept()[0] as connection:
                        connection.settimeout(9)
                        with connection.makefile("rb") as stream:
                            def line():
                                return stream.readline(16384).decode("utf-8").rstrip("\r\n")

                            def send(text):
                                # Split UTF-8 and CRLF across reads, including inside CJK text.
                                payload = (text + "\r\n").encode("utf-8")
                                for start in range(0, len(payload), 7):
                                    connection.sendall(payload[start:start + 7])
                                    time.sleep(0.001)

                            def commands(*expected):
                                actual = [line() for _ in expected]
                                assert actual == list(expected), "Unexpected fixture response"

                            commands("state on", "bytecount 1", "hold release")
                            if scenario == "idle-cancel":
                                assert line() == "", "Idle cancellation did not close socket"
                                return
                            if scenario == "invalid":
                                send(">PASSWORD:Verification Failed: 'Auth' ['CRV1:R,X:state:Y3Ix:PIN']")
                                assert line() == "", "Invalid challenge reused credentials"
                                return
                            if scenario == "unsupported":
                                connection.sendall(b"\xff\xfe\r\n")
                                assert line() == "", "Invalid UTF-8 was accepted"
                                return
                            if scenario == "cancel":
                                send(">PASSWORD:Verification Failed: 'Auth' ['CRV1:R:cancel:Y3Ix:设备确认']")
                                send(">STATE:1,RECONNECTING,auth-failure,,,,")
                                send(">HOLD:Waiting for hold release:1")
                                commands('hold release')
                                send(">PASSWORD:Need 'Auth' username/password")
                                assert line() == "", "Cancelled challenge produced credentials"
                                return
                            send(">PASSWORD:Need 'Auth' username/password")
                            commands('username "Auth" "fixture-user"', 'password "Auth" "fixture-password"')
                            send(">PASSWORD:Need 'Private Key' password")
                            commands('password "Private Key" "fixture-key"')
                            for flag in range(4):
                                prompt = "CONNECTED" if flag == 1 else "设备验证码"
                                send(f">PASSWORD:Need 'Auth' username/password SC:{flag},{prompt}")
                                if flag < 2:
                                    packed = "SCRV1:" + base64.b64encode(b"fixture-password").decode() + ":" + base64.b64encode(b"8675309").decode()
                                else:
                                    packed = "fixture-password8675309"
                                commands('username "Auth" "fixture-user"', f'password "Auth" "{packed}"')
                            for flags, state, response in [("R,E", "state-one", "8675309"), ("", "state-two", "")]:
                                send(f">PASSWORD:Verification Failed: 'Auth' ['CRV1:{flags}:{state}:Y3Ix:设备确认:下一步']")
                                send(">STATE:2,RECONNECTING,auth-failure,,,,")
                                send(">HOLD:Waiting for hold release:1")
                                commands('hold release')
                                send(">PASSWORD:Need 'Auth' username/password")
                                commands('username "Auth" "cr1"', f'password "Auth" "CRV1::{state}::{response}"')
                            send(">STATE:3,CONNECTED,SUCCESS,10.8.0.2,127.0.0.1")
                            send(">BYTECOUNT:100,200")
                except Exception as error:
                    errors.put(error)

            worker = threading.Thread(target=server, daemon=True)
            worker.start()
            completed = subprocess.run([helper, "--self-test-management", path, scenario], capture_output=True, text=True, timeout=12)
            worker.join(timeout=2)
            assert not worker.is_alive(), "Management fixture did not finish"
            if not errors.empty():
                raise errors.get()
            assert completed.returncode == 0, f"Management self-test failed: {scenario}\n{completed.stdout}\n{completed.stderr}"


if __name__ == "__main__":
    for name in ["happy", "invalid", "unsupported", "cancel"] + ["idle-cancel"] * 8:
        exercise(str(pathlib.Path(sys.argv[1]).resolve()), name)
    print("PASS: Unix management credentials, private key, static flags 0–3, CRV1, fragmented UTF-8, stale replies and concurrent cancellation.")
