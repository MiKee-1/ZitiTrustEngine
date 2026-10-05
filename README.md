# ZitiTrustEngine

Thesis lab: an external TrustEngine for OpenZiti in an OT/IT context
(gateways that poll a Modbus server and write to a historian).

Current state: network skeleton (Ziti controller/router, server-side
tunneler, historian) plus the three log sources from the thesis's roadmap
point 2 (Ziti controller events, Zeek on the Modbus traffic, osquery on
the gateways) and a synthetic Modbus server (`plc`) for them to observe.

## Start

```sh
docker compose up -d --build
```

`gateway-a`/`gateway-b` stay up idle (no checks run automatically). Trigger
the checks by hand, as many times as you want:

```sh
docker compose exec gateway-a python test_dial.py
docker compose exec gateway-b python test_dial.py
```

Each gateway runs `ziti-edge-tunnel` with its own identity (started by
`gateway/entrypoint.sh`), which intercepts `historian.ziti` and dials the
Ziti service on the scripts' behalf.

Each run verifies that the historian on the `it` network is unreachable
directly and reachable only by dialing the Ziti service `historian`, then
produces one Modbus read/write (for Zeek to observe) and two osquery
queries (written to `logs/osquery/`).

## IP to identity correlation

Zeek only sees IPs; the controller only sees identities. A login
(apiSession event) assigns its IP to that identity until the identity goes
offline (sdk-offline). To annotate every Modbus record with the identity
holding that IP at that time:

```sh
analysis/export_identities.sh    # optional: identity names, kept in logs/identities/
python3 analysis/ip_identity.py
```

Events only carry identity ids. Each export is kept in its own file because
a `down -v` recreates every identity with a new id: run the export after
every fresh start to name events from all of them.

## Identities

`ziti-setup` writes each enrolled identity into its own subdirectory of
the `ziti-identities` volume, and each container mounts only its own: no
gateway can read another identity's certificate and key.

## Logs

All runtime output lands in `logs/` (gitignored): controller events in
`logs/controller/events.json`, osquery results in `logs/osquery/`, and Zeek
logs in `logs/zeek/<UTC start time>/`, one directory per Zeek start so a
restart never truncates earlier logs.

## Full reset

```sh
docker compose down -v   # also wipes the controller's PKI
```
