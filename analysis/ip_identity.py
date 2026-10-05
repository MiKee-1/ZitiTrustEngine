"""Map the source IPs seen by Zeek to Ziti identities, using controller events.

Zeek only sees IP addresses (the gateway -> plc Modbus traffic never enters
the Ziti overlay); the controller only reasons in identities. This script
bridges the two and annotates every Modbus record in Zeek's modbus.log with
the identity that held that IP at that time.

Where the (identity, IP) association comes from:

  edge.apiSessions  a login, with ip_address: opens an interval in which the
                    IP belongs to that identity. A tunneler logs in once at
                    start and keeps that session, so the interval stays open
                    until the identity goes offline.
  sdk               sdk-offline closes the identity's open intervals. It is
                    per identity: with two instances of the same identity
                    (a cloned certificate) it only fires once both are gone.
  fabric.circuits   actual use of the service. No IP of its own, resolved
                    through circuit.client_id == edge.sessions.id and
                    session.api_session_id == edge.apiSessions.id; shown as
                    an extra source when close to a Modbus record.

The same identity holding two overlapping intervals from different IPs is
what a certificate used in parallel looks like: listed at the end.

Usage (from the repo root, stdlib only):

  analysis/export_identities.sh     # optional: identity names -> logs/identities/
  python3 analysis/ip_identity.py

Identities without a name in any export are printed as raw ids.
"""

import argparse
import collections
import glob
import json
from datetime import datetime, timezone

INF = float("inf")


def parse_ts(rfc3339):
    # Controller timestamps carry nanoseconds; datetime only takes microseconds.
    head, _, frac = rfc3339.rstrip("Z").partition(".")
    frac = (frac + "000000")[:6]
    return datetime.fromisoformat(f"{head}.{frac}+00:00").timestamp()


def fmt(ts):
    return "open" if ts == INF else datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def strip_port(addr):
    # "10.19.1.21:43052" -> "10.19.1.21"; legacy apiSessions have no port.
    return addr.rsplit(":", 1)[0] if addr.count(":") == 1 else addr


def load_events(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def build_intervals(events, names):
    """[start, end, ip, identity] per login, end = next sdk-offline or open."""
    intervals = []
    for e in sorted(events, key=lambda e: e["timestamp"]):
        ns, ts = e["namespace"], parse_ts(e["timestamp"])
        if ns == "edge.apiSessions" and e["event_type"] == "created":
            ip, ident = strip_port(e["ip_address"]), e["identity_id"]
            for iv in intervals:
                # After a `down -v` the same gateway comes back under a new id
                # from the same IP: the old id's interval ends here.
                if (iv[1] == INF and iv[2] == ip and iv[3] != ident
                        and ident in names and names.get(iv[3]) == names[ident]):
                    iv[1] = ts
            intervals.append([ts, INF, ip, ident])
        elif ns == "sdk" and e["event_type"] == "sdk-offline":
            for iv in intervals:
                if iv[3] == e["identity_id"] and iv[1] == INF:
                    iv[1] = ts
    return intervals


def circuit_sightings(events):
    """(time, ip, identity) per circuit, via circuit -> session -> apiSession."""
    api_sessions = {e["id"]: e for e in events
                    if e["namespace"] == "edge.apiSessions" and e["event_type"] == "created"}
    sessions = {e["id"]: e for e in events
                if e["namespace"] == "edge.sessions" and e["event_type"] == "created"}
    out = []
    for e in events:
        if e["namespace"] != "fabric.circuits" or e["event_type"] != "created":
            continue
        session = sessions.get(e["client_id"])
        api_session = api_sessions.get(session["api_session_id"]) if session else None
        if api_session:
            out.append((parse_ts(e["timestamp"]), strip_port(api_session["ip_address"]),
                        e["tags"]["clientId"]))
    return out


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


def load_names(pattern):
    # One file per export; ids never repeat across a `down -v`, so merging
    # every export names events from all incarnations seen so far.
    paths = sorted(glob.glob(pattern))
    if not paths:
        print(f"# no {pattern} (run analysis/export_identities.sh): showing raw ids")
    names = {}
    for path in paths:
        with open(path) as f:
            names.update({i["id"]: i["name"] for i in json.load(f)["data"]})
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--events", default="logs/controller/events.json")
    # Zeek writes one subdirectory per start (see docker-compose.yml): read them all.
    ap.add_argument("--zeek", default="logs/zeek/*/modbus.log",
                    help="modbus.log path or glob")
    ap.add_argument("--names", default="logs/identities/*.json",
                    help="identity exports, path or glob (see export_identities.sh)")
    ap.add_argument("--window", type=float, default=60.0,
                    help="seconds around a Modbus record in which a circuit counts as a source")
    args = ap.parse_args()

    names = load_names(args.names)
    name = lambda i: names.get(i, i)
    events = load_events(args.events)
    intervals = build_intervals(events, names)
    circuits = circuit_sightings(events)

    print(f"# {len(intervals)} logins, {len(circuits)} circuits")
    print("# ts\tsrc_ip\tfunc\tpdu\tidentity (sources)")
    records = [r for path in sorted(glob.glob(args.zeek)) for r in load_zeek(path)]
    for r in sorted(records, key=lambda r: float(r["ts"])):
        ts, ip = float(r["ts"]), r["id.orig_h"]
        holders = {iv[3] for iv in intervals if iv[2] == ip and iv[0] <= ts < iv[1]}
        used = {ident for c_ts, c_ip, ident in circuits
                if c_ip == ip and abs(c_ts - ts) <= args.window}
        if not holders:
            who = "UNKNOWN (no login from this IP)"
        else:
            who = ", ".join(f"{name(i)} (login{'+circuit' if i in used else ''})"
                            for i in sorted(holders))
            if len(holders) > 1:
                who = "AMBIGUOUS: " + who
        when = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")
        print(f"{when}\t{ip}\t{r['func']}\t{r['pdu_type']}\t{who}")

    print("\n# identities logged in from more than one IP at the same time")
    by_ident = collections.defaultdict(list)
    for iv in intervals:
        by_ident[iv[3]].append(iv)
    found = False
    for ident, ivs in by_ident.items():
        for i, a in enumerate(ivs):
            for b in ivs[i + 1:]:
                if a[2] != b[2] and a[0] < b[1] and b[0] < a[1]:
                    print(f"{name(ident)}\t{a[2]} [{fmt(a[0])} - {fmt(a[1])}]"
                          f"  vs  {b[2]} [{fmt(b[0])} - {fmt(b[1])}]")
                    found = True
    if not found:
        print("(none)")


if __name__ == "__main__":
    main()
