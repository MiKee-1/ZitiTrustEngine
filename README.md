# ZitiTrustEngine

Thesis lab: an external TrustEngine for OpenZiti in an OT/IT context
(gateways that poll a Modbus server and write to a historian).

Current state: the full lab the TrustEngine will observe. Two isolated
networks (`ot`, `it`) bridged only by the Ziti overlay; a synthetic Modbus
server (`plc`); two gateways, each running `ziti-edge-tunnel`, a polling
loop and `osqueryd`; a historian reachable only as a Ziti service, guarded
by a process posture check; and the log sources (Ziti controller events
and process log, Zeek on the Modbus traffic, osquery on the gateways).

## Start

```sh
docker compose up -d --build
analysis/export_identities.sh    # identity names, after every fresh start
```

On first start `ziti-setup` creates each identity and leaves only its
one-time enrollment token; the container that uses the identity enrolls it
(the gateways in `gateway/entrypoint.sh`, `ziti-host` in its image's own
entrypoint), so each private key is generated where it is used.

Each gateway then runs only `ziti-edge-tunnel`. Nothing else starts on its
own: the polling loop and osquery are started by hand, when a recording
period begins.

Before the controller starts, the one-shot `logs-init` service creates the
`logs/` directories the containers write into, if missing, and makes them
writable by everyone (777) on every `up`: a bind-mount source that Docker
creates on its own belongs to root with mode 755, and the controller runs
as uid 2171.

## Versions

The OpenZiti versions are pinned in `.env`: `ZITI_VERSION` (controller,
router, `ziti-setup`) and `ZITI_TUNNEL_VERSION` (`ziti-edge-tunnel` in the
gateways and the `ziti-host` image). With a v2.x controller the tunneler
never delivers the process posture check's result, so every gateway dial
is denied. After changing `ZITI_VERSION`, start from scratch
(`docker compose down -v`): the controller's database and PKI were created
by the previous version.

## Polling loop and osquery

```sh
docker compose exec -d gateway-a gateway-poller poller.py
docker compose exec -d gateway-a bash osqueryd.sh
# same for gateway-b
```

- `gateway/poller.py` reads holding register 0 from the `plc` every 10 s
  (reads only) and posts it to `http://historian.ziti:5000`, which the
  tunneler intercepts and carries over the overlay. One line per cycle in
  `logs/poller/<gateway>/`.
- `osqueryd` runs the scheduled queries in `gateway/osquery.conf`
  (processes and sockets on port 502) every 30 s; results in
  `logs/osquery/<gateway>/osqueryd.snapshots.log`.

Both keep a pid file, so a second instance in the same gateway is refused.
Each gateway mounts only its own `logs/osquery/<gateway>/` and
`logs/poller/<gateway>/`, so a compromised gateway cannot rewrite the
other one's logs.
They stop when the container is recreated and have to be started again.

## Process posture check

The historian's dial policy requires the posture check `poller-running`:
a gateway may dial the historian only while
`/usr/local/bin/gateway-poller` is running. That executable is a copy of
the Python interpreter used only by the polling loop, since the check
matches the executable path, not the command line. The gateways need
`SYS_PTRACE`: the tunneler switches to the `ziti` group at startup and
could not otherwise see the other processes' executables.

A denied dial does not appear in the controller's event log. To save each
gateway's reported posture and the controller's list of denied dials
(kept only in memory, lost on a controller restart, and limited to the
last 100 denials per identity):

```sh
analysis/posture_status.sh       # writes logs/posture/<UTC time>.json
```

## Checks

```sh
docker compose exec gateway-a python test_dial.py
```

Verifies that the historian on the `it` network is unreachable directly
and reachable only by dialing the Ziti service `historian` (which, with
the posture check, requires the polling loop to be running), then produces
one Modbus read **and one write** and two osquery queries. The write is
exactly what the TrustEngine will flag as anomalous: do not run it during
a recording of normal behaviour.

## Scenario runs

Each scenario is produced on purpose in a short run with known start and
end, so that the logs of every run can be matched against what actually
happened. With the lab up:

```sh
scenarios/control.sh             # no attack: normal behaviour
scenarios/poller_stopped.sh      # reference case: polling loop stopped
```

Every run has three timed phases, `normal-before`, `attack` and
`normal-after` (300, 600 and 300 s by default; set `NORMAL_BEFORE`,
`ATTACK`, `NORMAL_AFTER` to change them). The scripts never start or stop
the stack; they start the polling loop and osquery on the gateways only if
they are not running, and wait for a successful post first.

The ground truth of each run is `logs/runs/<run id>.jsonl`: one JSON line
per event (run start with its parameters and the code commit, phase
boundaries, attack actions), timed by the lab's own clock. It is the label
to check the TrustEngine against, not one of its sources. Commit before a
run: uncommitted changes are recorded as `dirty`. Identity names are exported
before the first phase and the posture data after the last one.

`poller_stopped.sh` copies `scenarios/probe.py` into the gateway: it dials
the historian every second during the attack phase, so the moment the
posture check starts denying shows up in `logs/runs/<run id>.probe.log`
and in the denied dials of the posture export.

After each run, stop the lab and move `logs/` aside before the next one,
so that every run has its own set of logs.

## IP to identity correlation

Zeek only sees IPs; the controller only sees identities. A login
(apiSession event) assigns its IP to that identity until the identity goes
offline (sdk-offline). To annotate every Modbus record with the identity
holding that IP at that time:

```sh
python3 analysis/ip_identity.py
```

Events only carry identity ids. Each export of `export_identities.sh` is
kept in its own file because a `down -v` recreates every identity with a
new id.

## Logs

All runtime output lands in `logs/` (gitignored):

| Path | Content |
|---|---|
| `logs/controller/events.json` | controller events: logins, sessions, circuits, online/offline (successes only) |
| `logs/controller/controller.log` | controller process log in JSON: the only place failed logins show up |
| `logs/zeek/<UTC start time>/` | Zeek logs, one directory per Zeek start (`modbus.log` is the one that matters) |
| `logs/osquery/<gateway>/` | `osqueryd` scheduled query results |
| `logs/poller/<gateway>/` | one line per polling cycle |
| `logs/posture/` | `posture_status.sh` exports |
| `logs/identities/` | `export_identities.sh` exports |
| `logs/runs/` | scenario runs: ground truth (`<run id>.jsonl`) and probe output |

The historian's own data (readings and a log of every request) is in the
`historian-data` volume.

## Full reset

```sh
docker compose down -v   # wipes the controller's PKI, every identity and the historian
```
