import os
import socket
import sys
import time

import openziti
import requests

GATEWAY_ID = os.environ.get("GATEWAY_ID", "gateway-a")
IDENTITY_FILE = f"/identities/{GATEWAY_ID}.json"
HISTORIAN_IP = os.environ.get("HISTORIAN_IP", "10.19.2.30")
HISTORIAN_PORT = int(os.environ.get("HISTORIAN_PORT", "5000"))


def log(msg):
    print(f"[{GATEWAY_ID}] {msg}", flush=True)


def wait_for_identity():
    log(f"waiting for identity file {IDENTITY_FILE} ...")
    for _ in range(60):
        if os.path.exists(IDENTITY_FILE):
            return
        time.sleep(2)
    log("identity file never appeared, aborting")
    sys.exit(1)


def test_direct_unreachable():
    log(f"--- test 1: {HISTORIAN_IP}:{HISTORIAN_PORT} must be UNREACHABLE directly ---")
    try:
        s = socket.create_connection((HISTORIAN_IP, HISTORIAN_PORT), timeout=4)
        s.close()
        log("UNEXPECTED: the direct connection succeeded! ot/it isolation does not hold.")
        return False
    except OSError as e:
        log(f"OK (failed as expected): {e}")
        return True


def test_ziti_dial():
    log("--- test 2: dialing the Ziti service 'historian' must SUCCEED ---")
    openziti.load(IDENTITY_FILE)
    try:
        with openziti.monkeypatch():
            r = requests.get(f"http://historian.ziti:{HISTORIAN_PORT}/health", timeout=10)
        log(f"dial succeeded: status={r.status_code} body={r.text.strip()}")
        return r.status_code == 200
    except Exception as e:
        log(f"dial failed: {e}")
        return False


def main():
    wait_for_identity()
    direct_isolated = test_direct_unreachable()
    ziti_ok = test_ziti_dial()
    log(f"--- RESULT: direct_isolation_ok={direct_isolated} ziti_dial_ok={ziti_ok} ---")
    sys.exit(0 if (direct_isolated and ziti_ok) else 1)


if __name__ == "__main__":
    main()
