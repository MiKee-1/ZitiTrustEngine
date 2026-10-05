import json
import os
import socket
import subprocess
import sys
import time

import requests
from pymodbus.client import ModbusTcpClient

GATEWAY_ID = os.environ.get("GATEWAY_ID", "gateway-a")
HISTORIAN_IP = os.environ.get("HISTORIAN_IP", "10.19.2.30")
HISTORIAN_PORT = int(os.environ.get("HISTORIAN_PORT", "5000"))
PLC_IP = os.environ.get("PLC_IP", "10.19.1.30")
PLC_PORT = int(os.environ.get("PLC_PORT", "502"))
OSQUERY_LOG_DIR = os.environ.get("OSQUERY_LOG_DIR", "/logs")


def log(msg):
    print(f"[{GATEWAY_ID}] {msg}", flush=True)


def wait_for_tunnel():
    # ziti-edge-tunnel (started by entrypoint.sh) answers historian.ziti with
    # an intercept IP once it has authenticated and received the service list.
    log("waiting for ziti-edge-tunnel to intercept historian.ziti ...")
    for _ in range(30):
        try:
            ip = socket.gethostbyname("historian.ziti")
            log(f"historian.ziti -> {ip} (intercepted by the tunneler)")
            return
        except OSError:
            time.sleep(2)
    log("historian.ziti never resolved: is ziti-edge-tunnel running? aborting")
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
    # Plain HTTP: the dial happens in ziti-edge-tunnel, which intercepts the
    # connection on its tun interface and carries it over the overlay.
    try:
        r = requests.get(f"http://historian.ziti:{HISTORIAN_PORT}/health", timeout=10)
        log(f"dial succeeded: status={r.status_code} body={r.text.strip()}")
        return r.status_code == 200
    except Exception as e:
        log(f"dial failed: {e}")
        return False


def probe_modbus():
    # Deliberately produces one Modbus read and one Modbus write against the
    # plc, on the ot network, outside the Ziti overlay. Zeek (sharing the
    # plc's network namespace) is what's expected to log this traffic.
    log(f"--- modbus probe: read + write against {PLC_IP}:{PLC_PORT} ---")
    try:
        client = ModbusTcpClient(PLC_IP, port=PLC_PORT)
        if not client.connect():
            log("modbus probe: could not connect to plc")
            return
        rr = client.read_holding_registers(0, count=1, device_id=0)
        if rr.isError():
            log(f"modbus read failed: {rr}")
        else:
            log(f"modbus read holding register 0 -> {rr.registers}")
        wr = client.write_register(1, 999, device_id=0)
        if wr.isError():
            log(f"modbus write failed: {wr}")
        else:
            log("modbus write register 1 = 999 -> ok")
        client.close()
    except Exception as e:
        log(f"modbus probe failed: {e}")


def probe_osquery():
    # Two distinct queries, deliberately: one about the running process
    # (what a posture check would see), one about open sockets (what's
    # actually talking on the network). Written to a file so the real
    # osquery output format/fields can be inspected afterwards.
    log("--- osquery probe: two queries ---")
    queries = [
        "SELECT pid, name, cmdline, uid FROM processes WHERE name LIKE '%python%';",
        "SELECT pid, local_address, local_port, remote_address, remote_port, state "
        "FROM process_open_sockets WHERE local_port = 502 OR remote_port = 502;",
    ]
    results = []
    for q in queries:
        entry = {"query": q}
        try:
            out = subprocess.run(
                ["osqueryi", "--json", q], capture_output=True, text=True, timeout=30
            )
            entry["rows"] = json.loads(out.stdout) if out.stdout.strip() else []
            entry["stderr"] = out.stderr.strip()
            log(f"osquery ok: {q[:60]}... -> {len(entry['rows'])} row(s)")
        except Exception as e:
            entry["error"] = str(e)
            log(f"osquery query failed: {e}")
        results.append(entry)

    os.makedirs(OSQUERY_LOG_DIR, exist_ok=True)
    out_path = os.path.join(OSQUERY_LOG_DIR, f"osquery-{GATEWAY_ID}.json")
    try:
        with open(out_path, "w") as f:
            json.dump(results, f, indent=2)
        log(f"osquery results written to {out_path}")
    except Exception as e:
        log(f"could not write osquery results to {out_path}: {e}")


def main():
    wait_for_tunnel()
    direct_isolated = test_direct_unreachable()
    ziti_ok = test_ziti_dial()
    probe_modbus()
    probe_osquery()
    log(f"--- RESULT: direct_isolation_ok={direct_isolated} ziti_dial_ok={ziti_ok} ---")
    sys.exit(0 if (direct_isolated and ziti_ok) else 1)


if __name__ == "__main__":
    main()
