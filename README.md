# ZitiTrustEngine

Thesis lab: an external TrustEngine for OpenZiti in an OT/IT context
(gateways that poll a Modbus server and write to a historian).

Current state: just the network skeleton (Ziti controller/router,
server-side tunneler, historian, two verification gateways).

## Start

```sh
docker compose up -d --build
docker compose logs gateway-a gateway-b
```

The two `gateway-a`/`gateway-b` containers run a one-shot test: they verify
that the historian on the `it` network is unreachable directly and reachable
only by dialing the Ziti service `historian`.

## Full reset

```sh
docker compose down -v   # also wipes the controller's PKI
```
