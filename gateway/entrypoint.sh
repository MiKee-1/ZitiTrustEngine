#!/bin/bash
# Gateway entrypoint: starts ziti-edge-tunnel in the background with this
# gateway's own identity, then stays up idle. Checks are run by hand with
# `docker compose exec gateway-a python test_dial.py`.
#
# The tunneler creates the ziti0 tun interface, routes 100.64.0.0/10 through
# it, and prepends its own resolver (100.64.0.2) to /etc/resolv.conf: names
# of Ziti services (historian.ziti) resolve to an intercept IP, everything
# else falls through to Docker's embedded DNS (127.0.0.11), so plc and
# ziti-controller keep resolving as before.
#
# The identity volume is mounted read-only: the tunneler logs an error when
# it tries to write back updated config into the identity file, which is
# harmless here (nothing it needs to persist across restarts in this lab).
#
# If the tunneler dies the container stays up on purpose: a gateway whose
# Ziti client stopped is itself one of the cases under study.
set -euo pipefail

GATEWAY_ID="${GATEWAY_ID:?GATEWAY_ID not set}"
IDENTITY_FILE="/identities/${GATEWAY_ID}.json"

echo "[entrypoint] waiting for identity ${IDENTITY_FILE} ..."
until [ -f "${IDENTITY_FILE}" ]; do sleep 2; done

echo "[entrypoint] starting ziti-edge-tunnel for ${GATEWAY_ID}"
ziti-edge-tunnel run -i "${IDENTITY_FILE}" &

exec sleep infinity
