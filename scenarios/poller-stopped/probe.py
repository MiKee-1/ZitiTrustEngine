"""Measurement probe for the scenario runs.

Dials the historian through the Ziti tunnel every <interval> seconds for
<duration> seconds and prints one line per attempt: UTC time, outcome,
duration. Copied into a gateway by a scenario script and run there with
the standard interpreter, so it does not satisfy the process posture check
itself: it can dial only while gateway-poller is running.

    python /tmp/probe.py <duration s> <interval s>

Its pid is kept in /tmp/probe.pid, so the scenario script can stop it
early.
"""

import datetime
import os
import sys
import time

import requests

URL = "http://historian.ziti:5000/health"


def utc_now():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def main():
    duration, interval = float(sys.argv[1]), float(sys.argv[2])
    with open("/tmp/probe.pid", "w") as f:
        f.write(str(os.getpid()))
    end = time.monotonic() + duration
    next_run = time.monotonic()
    while next_run < end:
        t0 = time.monotonic()
        try:
            result = f"status={requests.get(URL, timeout=3).status_code}"
        except requests.RequestException as e:
            result = f"error={e.__class__.__name__}"
        ms = int((time.monotonic() - t0) * 1000)
        print(f"{utc_now()} {result} {ms}ms", flush=True)
        next_run += interval
        time.sleep(max(0.0, next_run - time.monotonic()))


if __name__ == "__main__":
    main()
