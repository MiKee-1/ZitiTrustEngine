"""Map the source IPs seen by Zeek to Ziti identities, using controller events.

Zeek only sees IP addresses (the gateway -> plc Modbus traffic never enters
the Ziti overlay); the controller only reasons in identities. This script
bridges the two by collecting "sightings" - (time, IP, identity) triples -
from the controller's event stream, then annotating every Modbus record in
Zeek's modbus.log with the identities seen at that IP around that time.

Sightings come from three event types:

  connect           identity -> ctrl / identity -> router connections, with
                    src_addr. Emitted on every controller API call, so a
                    running tunneler produces one roughly every refresh
                    interval: a continuous, authenticated (identity, IP) feed.
  edge.apiSessions  ip_address at login time.
  fabric.circuits   no IP of its own: resolved through
                    circuit.client_id == edge.sessions.id,
                    session.api_session_id == edge.apiSessions.id -> ip_address.

Usage (from the repo root, stdlib only):

  python3 analysis/ip_identity.py
  python3 analysis/ip_identity.py --names identities.json --window 60

where identities.json is the output of `ziti edge list identities -j`.
"""

import argparse
import collections
import json
from datetime import datetime


def parse_ts(rfc3339):
    # Controller timestamps carry nanoseconds; datetime only takes microseconds.
    head, _, frac = rfc3339.rstrip("Z").partition(".")
    frac = (frac + "000000")[:6]
    return datetime.fromisoformat(f"{head}.{frac}+00:00").timestamp()


def strip_port(addr):
    # "10.19.1.21:43052" -> "10.19.1.21"; legacy apiSessions have no port.
    return addr.rsplit(":", 1)[0] if addr.count(":") == 1 else addr


def load_events(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def collect_sightings(events):
    sightings = []
    api_sessions = {}
    sessions = {}
    for e in events:
        ns = e["namespace"]
        if ns == "connect" and e.get("src_type") == "identity":
            sightings.append((parse_ts(e["timestamp"]), strip_port(e["src_addr"]),
                              e["src_id"], f"connect:{e['dst_type']}"))
        elif ns == "edge.apiSessions" and e["event_type"] == "created":
            api_sessions[e["id"]] = e
            sightings.append((parse_ts(e["timestamp"]), strip_port(e["ip_address"]),
                              e["identity_id"], "apiSession"))
        elif ns == "edge.sessions" and e["event_type"] == "created":
            sessions[e["id"]] = e
    for e in events:
        if e["namespace"] != "fabric.circuits" or e["event_type"] != "created":
            continue
        session = sessions.get(e["client_id"])
        api_session = api_sessions.get(session["api_session_id"]) if session else None
        if api_session is None:
            continue
        sightings.append((parse_ts(e["timestamp"]), strip_port(api_session["ip_address"]),
                          e["tags"]["clientId"], "circuit"))
    sightings.sort()
    return sightings


def load_zeek(path):
    fields, rows = None, []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#fields"):
                fields = line.split("\t")[1:]
            elif line and not line.startswith("#"):
                rows.append(dict(zip(fields, line.split("\t"))))
    return rows


def load_names(path):
    if not path:
        return {}
    with open(path) as f:
        return {i["id"]: i["name"] for i in json.load(f)["data"]}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--events", default="logs/controller/events.json")
    ap.add_argument("--zeek", default="logs/zeek/modbus.log")
    ap.add_argument("--names", help="output of `ziti edge list identities -j`")
    ap.add_argument("--window", type=float, default=60.0,
                    help="seconds before/after a Modbus record to look for sightings")
    args = ap.parse_args()

    names = load_names(args.names)
    name = lambda i: names.get(i, i)
    sightings = collect_sightings(load_events(args.events))
    by_ip = collections.defaultdict(list)
    for ts, ip, ident, src in sightings:
        by_ip[ip].append((ts, ident, src))

    print(f"# {len(sightings)} sightings, window +/-{args.window:g}s")
    print("# ts\tsrc_ip\tfunc\tpdu\tidentities (sources)")
    for r in load_zeek(args.zeek):
        ts, ip = float(r["ts"]), r["id.orig_h"]
        near = collections.defaultdict(set)
        for s_ts, ident, src in by_ip.get(ip, []):
            if abs(s_ts - ts) <= args.window:
                near[ident].add(src)
        if not near:
            who = "UNKNOWN (no sighting)"
        else:
            who = ", ".join(f"{name(i)} ({'+'.join(sorted(s))})" for i, s in sorted(near.items()))
            if len(near) > 1:
                who = "AMBIGUOUS: " + who
        when = datetime.utcfromtimestamp(ts).strftime("%Y-%m-%dT%H:%M:%S.%f")
        print(f"{when}\t{ip}\t{r['func']}\t{r['pdu_type']}\t{who}")

    # The reverse view: one identity seen from more than one IP within the
    # same window is what a certificate used in parallel looks like.
    print("\n# identities seen from more than one IP within the window")
    by_ident = collections.defaultdict(list)
    for ts, ip, ident, _ in sightings:
        by_ident[ident].append((ts, ip))
    found = False
    for ident, seen in by_ident.items():
        for i, (ts_a, ip_a) in enumerate(seen):
            clash = {ip for ts_b, ip in seen[i + 1:] if ts_b - ts_a <= args.window and ip != ip_a}
            if clash:
                when = datetime.utcfromtimestamp(ts_a).strftime("%Y-%m-%dT%H:%M:%S")
                print(f"{when}\t{name(ident)}\t{ip_a} vs {', '.join(sorted(clash))}")
                found = True
                break
    if not found:
        print("(none)")


if __name__ == "__main__":
    main()
