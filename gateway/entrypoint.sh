#!/bin/bash
# Gateway entrypoint: starts ziti-edge-tunnel in the background with this
# gateway's own identity, then stays up idle. Nothing else starts on its
# own: the polling loop (poller.py), osqueryd (osqueryd.sh) and the checks
# (test_dial.py) are started by hand with `docker compose exec`.
#
# The tunneler creates the ziti0 tun interface, routes 100.64.0.0/10 through
# it, and prepends its own resolver (100.64.0.2) to /etc/resolv.conf: names
# of Ziti services (historian.ziti) resolve to an intercept IP, everything
# else falls through to Docker's embedded DNS (127.0.0.11), so plc and
# ziti-controller keep resolving as before.
#
# On first start the identity directory holds only the enrollment token
# written by ziti-setup: the tunneler enrolls it, generating the private key
# here, and the token is removed. The directory is the only one of the
# identity volume mounted into this container.
#
# If the tunneler dies the container stays up on purpose: a gateway whose
# Ziti client stopped is itself one of the cases under study.
set -euo pipefail

GATEWAY_ID="${GATEWAY_ID:?GATEWAY_ID not set}"
IDENTITY_FILE="/identities/${GATEWAY_ID}.json"
JWT_FILE="/identities/${GATEWAY_ID}.jwt"

echo "[entrypoint] waiting for identity ${IDENTITY_FILE} or token ${JWT_FILE} ..."
until [ -f "${IDENTITY_FILE}" ] || [ -f "${JWT_FILE}" ]; do sleep 2; done

if [ ! -f "${IDENTITY_FILE}" ]; then
  echo "[entrypoint] enrolling ${GATEWAY_ID}"
  ziti-edge-tunnel enroll --jwt "${JWT_FILE}" --identity "${IDENTITY_FILE}"
  rm -f "${JWT_FILE}"
fi

echo "[entrypoint] starting ziti-edge-tunnel for ${GATEWAY_ID}"
ziti-edge-tunnel run -i "${IDENTITY_FILE}" &

exec sleep infinity
