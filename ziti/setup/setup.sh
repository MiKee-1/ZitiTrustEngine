#!/bin/bash
# One-shot container: configures Ziti identities, service and policies for the lab.
# Runs on the openziti/quickstart image (already has the "ziti" CLI and "jq"), attached
# only to the "it" network, and talks to the controller's Edge MANAGEMENT API (port 1281,
# reachable only from there). At the end it leaves the enrolled identities' .json files
# in /identities, shared via volume with ziti-host and the gateways.
set -euo pipefail

export PATH="/var/openziti/ziti-bin:${PATH}"

CTRL_MGMT="${ZITI_CTRL_MGMT_ADDR:?ZITI_CTRL_MGMT_ADDR not set}"
ZITI_USER="${ZITI_USER:-admin}"
ZITI_PWD="${ZITI_PWD:?ZITI_PWD not set}"
ROUTER_NAME="${ZITI_ROUTER_NAME:-ziti-router}"

echo "[setup] waiting for the controller's Edge Management API at ${CTRL_MGMT} ..."
until ziti edge login "${CTRL_MGMT}" -u "${ZITI_USER}" -p "${ZITI_PWD}" -y >/tmp/login.log 2>&1; do
  echo "[setup]   controller not ready yet, retrying in 3s..."
  sleep 3
done
echo "[setup] login ok."

echo "[setup] waiting for router '${ROUTER_NAME}' to come online..."
router_online=0
for _ in $(seq 1 40); do
  if ziti edge list edge-routers "name=\"${ROUTER_NAME}\"" -j 2>/dev/null | jq -e '.data[0].isOnline == true' >/dev/null 2>&1; then
    router_online=1
    break
  fi
  sleep 3
done
if [ "${router_online}" != "1" ]; then
  echo "[setup] ERROR: the router never came online, aborting."
  exit 1
fi
echo "[setup] router online."

echo "[setup] edge-router-policy / service-edge-router-policy (single router, serves everything)..."
ziti edge create edge-router-policy allEdgeRouters --edge-router-roles '#all' --identity-roles '#all' \
  || echo "[setup]   already exists, continuing"
ziti edge create service-edge-router-policy allSvcAllRouters --edge-router-roles '#all' --service-roles '#all' \
  || echo "[setup]   already exists, continuing"

mkdir -p /identities

create_identity() {
  local name="$1"
  if [ -f "/identities/${name}.json" ]; then
    echo "[setup] identity ${name} already enrolled, skipping"
    return
  fi
  echo "[setup] creating identity ${name}"
  ziti edge create identity "${name}" -o "/identities/${name}.jwt"
  echo "[setup] enrolling ${name}"
  ziti edge enroll "/identities/${name}.jwt"
  rm -f "/identities/${name}.jwt"
}

create_identity gateway-a
create_identity gateway-b
create_identity ziti-host

echo "[setup] tagging identities with the role attributes used by the policies..."
ziti edge update identity gateway-a --role-attributes gateway
ziti edge update identity gateway-b --role-attributes gateway
ziti edge update identity ziti-host --role-attributes historian-host

echo "[setup] configs for the historian service..."
ziti edge create config historian-intercept.v1 intercept.v1 \
  '{"protocols":["tcp"],"addresses":["historian.ziti"],"portRanges":[{"low":5000,"high":5000}]}' \
  || echo "[setup]   intercept config already exists"
ziti edge create config historian-host.v1 host.v1 \
  '{"protocol":"tcp","address":"historian","port":5000}' \
  || echo "[setup]   host config already exists"

echo "[setup] historian service..."
ziti edge create service historian --configs historian-intercept.v1,historian-host.v1 \
  || echo "[setup]   service already exists"

echo "[setup] service policies (dial for the gateways, bind for ziti-host)..."
ziti edge create service-policy historian-dial Dial --service-roles '@historian' --identity-roles '#gateway' \
  || echo "[setup]   dial policy already exists"
ziti edge create service-policy historian-bind Bind --service-roles '@historian' --identity-roles '#historian-host' \
  || echo "[setup]   bind policy already exists"

echo "[setup] done."
