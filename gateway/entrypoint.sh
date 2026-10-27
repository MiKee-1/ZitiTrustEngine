#!/bin/bash
# Gateway entrypoint: starts ziti-edge-tunnel with this gateway's own
# identity, then osqueryd (osqueryd.sh) and the polling loop (poller.py), all
# in the background, and stays up idle, like a gateway whose services start
# at boot. Only the checks (test_dial.py) are started by hand.
#
# The polling loop and osqueryd keep pid files (/run/poller.pid,
# /var/osquery/osqueryd.pidfile) that refuse a second instance. Stopping
# the stack kills them without a chance to clean up, so those files are
# left behind, and on the next start the pids are handed out in the same
# order: a new process could find its own pid in an old file and exit.
# Nothing runs yet at this point, so any pid file found here is stale and
# is removed.
#
# PID 1 is Docker's init (init: true in docker-compose.yml), which reaps
# the processes that end; this script runs under it and ends as
# sleep infinity. The three services are started from a subshell that
# exits right away, so that PID 1 adopts them: osquery reports parent 1,
# and when one is stopped PID 1 reaps it instead of leaving a zombie. The
# scenario scripts restart the polling loop the same way, so the restarted
# one looks the same.
#
# If the tunneler is not ready yet, the polling loop's first cycles fail
# and it carries on; the first cycle after the tunneler is up is denied by
# the posture check, as on every start of the loop.
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
( ziti-edge-tunnel run -i "${IDENTITY_FILE}" & )

rm -f /run/poller.pid /var/osquery/osqueryd.pidfile
echo "[entrypoint] starting osqueryd and the polling loop"
( bash /app/osqueryd.sh < /dev/null > /dev/null 2>&1 & )
( gateway-poller poller.py < /dev/null > /dev/null 2>&1 & )

exec sleep infinity
