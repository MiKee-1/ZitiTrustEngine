"""Gateway polling loop: the normal behaviour of a gateway.

Every POLL_INTERVAL seconds it reads holding register 0 from the plc and
posts the value to the historian. Only Modbus reads: a write from a gateway
is the signal of the "compromised gateway" scenario, so the normal loop
never produces one.

The historian is reached at historian.ziti, intercepted by ziti-edge-tunnel
(started by entrypoint.sh): plain HTTP here, the dial happens in the
tunneler.

Started by hand, detached, when a recording period begins:

    docker compose exec -d gateway-a gateway-poller poller.py

gateway-poller is a copy of the Python interpreter (see the Dockerfile):
the process posture check on the historian's dial policy requires that
executable to be running, so the gateway can reach the historian only
while this loop is up.

One line per cycle is appended to logs/poller/<gateway>/poller-<gateway>.log
(only that directory is mounted into the gateway, at /logs/poller). A pid
file prevents a second instance in the same gateway (it would double the
polling rate seen by Zeek and the controller).
"""

import logging
import os
import signal
import sys
import threading
import time

import requests
from pymodbus.client import ModbusTcpClient

GATEWAY_ID = os.environ.get("GATEWAY_ID", "gateway-a")
PLC_IP = os.environ.get("PLC_IP", "10.19.1.30")
PLC_PORT = int(os.environ.get("PLC_PORT", "502"))
HISTORIAN_URL = os.environ.get(
    "HISTORIAN_URL", "http://historian.ziti:5000/api/readings"
)
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "10"))
LOG_DIR = os.environ.get("POLLER_LOG_DIR", "/logs/poller")
PID_FILE = "/run/poller.pid"

stop = threading.Event()


def setup_logging():
    os.makedirs(LOG_DIR, exist_ok=True)
    fmt = logging.Formatter(
        "%(asctime)s.%(msecs)03dZ " + GATEWAY_ID + " %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    fmt.converter = time.gmtime
    log = logging.getLogger("poller")
    log.setLevel(logging.INFO)
    for handler in (
        logging.FileHandler(os.path.join(LOG_DIR, f"poller-{GATEWAY_ID}.log")),
        logging.StreamHandler(sys.stdout),
    ):
        handler.setFormatter(fmt)
        log.addHandler(handler)
    return log


def acquire_pid_file(log):
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        log.info(f"already running (pid {pid}), not starting a second instance")
        sys.exit(1)
    except (FileNotFoundError, ValueError, ProcessLookupError):
        pass
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


def read_register(client):
    # Keeps one Modbus/TCP connection open across cycles, like a real
    # gateway; reconnects on the next cycle if it drops.
    if not client.connected and not client.connect():
        return None, "plc unreachable"
    try:
        rr = client.read_holding_registers(0, count=1, device_id=0)
    except Exception as e:
        client.close()
        return None, f"read failed: {e}"
    if rr.isError():
        return None, f"read error: {rr}"
    return rr.registers[0], None


def post_reading(session, value):
    try:
        r = session.post(
            HISTORIAN_URL, json={"gateway": GATEWAY_ID, "value": value}, timeout=5
        )
        return r.status_code, None
    except requests.RequestException as e:
        return None, f"post failed: {e.__class__.__name__}: {e}"


def main():
    log = setup_logging()
    acquire_pid_file(log)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())

    log.info(
        f"start: plc={PLC_IP}:{PLC_PORT} historian={HISTORIAN_URL} "
        f"interval={POLL_INTERVAL}s pid={os.getpid()}"
    )
    client = ModbusTcpClient(PLC_IP, port=PLC_PORT, timeout=3)
    session = requests.Session()

    # Fixed-rate schedule on the monotonic clock: the polling rhythm is part
    # of the baseline, so a slow cycle must not shift all the next ones.
    next_run = time.monotonic()
    try:
        while not stop.is_set():
            value, err = read_register(client)
            if err:
                log.info(f"read=- post=- {err}")
            else:
                t0 = time.monotonic()
                status, err = post_reading(session, value)
                ms = int((time.monotonic() - t0) * 1000)
                log.info(f"read={value} post={status or '-'} {ms}ms {err or ''}".rstrip())

            next_run += POLL_INTERVAL
            delay = next_run - time.monotonic()
            if delay < 0:
                # fell behind (e.g. timeouts): skip missed slots, keep the phase
                next_run += -delay // POLL_INTERVAL * POLL_INTERVAL + POLL_INTERVAL
                delay = next_run - time.monotonic()
            stop.wait(delay)
    finally:
        client.close()
        log.info("stop")
        try:
            os.remove(PID_FILE)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
