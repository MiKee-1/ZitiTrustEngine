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

Zeek only sees IPs; the controller only sees identities. To annotate every
Modbus record with the Ziti identity seen at that IP (from controller
`connect`, apiSession and circuit events):

```sh
python3 analysis/ip_identity.py --names identities.json   # from `ziti edge list identities -j`
```

## Known limitation: shared identity volume

The `ziti-identities` volume holds every enrolled identity (certificate and
private key) and is mounted whole into both gateways. Each tunneler is
pinned to its own file with `-i`, but any process in `gateway-a` can read
`/identities/gateway-b.json` and `/identities/ziti-host.json`. In a real
deployment each identity would exist only on the host that uses it. Kept
for now as a lab shortcut; it is also the reason the cloned-certificate
scenario needs no extra setup.

## Full reset

```sh
docker compose down -v   # also wipes the controller's PKI
```
