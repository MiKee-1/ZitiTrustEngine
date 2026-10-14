#!/bin/bash
# One-shot container: configures Ziti identities, service and policies for the lab.
# Runs on the openziti/quickstart image (already has the "ziti" CLI and "jq"), attached
# only to the "it" network, and talks to the controller's Edge MANAGEMENT API (port 1281,
# reachable only from there). It creates each identity and leaves its one-time
# enrollment token in /identities/<name>/<name>.jwt, on a volume whose subdirectories
# are mounted one per container: the container that uses the identity enrolls it on
# first start, so the private key is generated where it is used and never leaves it.
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

# Each identity goes in its own subdirectory (/identities/<name>/): docker-compose.yml
# mounts only that subdirectory into the container that uses it, so no container can
# read another one's certificate and key.
#
# Only the enrollment token is written here. Enrollment is done by ziti-edge-tunnel in
# the container that owns the identity (gateway/entrypoint.sh for the gateways, the
# openziti/ziti-host image's own entrypoint for ziti-host), which generates its own key.
# Identities enrolled here with "ziti edge enroll" (RSA keys) failed the tunneler's TLS
# handshake with the controller's OIDC endpoint; tunneler-enrolled ones (EC keys) work.
create_identity() {
  local name="$1"
  local dir="/identities/${name}"
  if [ -f "${dir}/${name}.json" ] || [ -f "${dir}/${name}.jwt" ]; then
    echo "[setup] identity ${name} already created, skipping"
    return
  fi
  mkdir -p "${dir}"
  echo "[setup] creating identity ${name} (enrollment token only)"
  ziti edge create identity "${name}" -o "${dir}/${name}.jwt"
}

create_identity gateway-a
create_identity gateway-b
create_identity ziti-host
# ziti-host runs as nobody:ziti (65534:2171) and writes its enrolled identity, a
# backup and config updates in its directory, so the directory must belong to it.
chown -R 65534:2171 /identities/ziti-host

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

# Process posture check: a gateway may dial the historian only while its
# polling loop is running. The tunneler reports which executables are
# running, and the check matches the executable path, not the command line:
# the poller runs under a dedicated copy of the Python interpreter
# (gateway/Dockerfile), so any other Python script on the gateway does not
# satisfy it. Path only, no binary hash.
echo "[setup] process posture check for the gateways' polling loop..."
ziti edge create posture-check process poller-running Linux /usr/local/bin/gateway-poller \
  --role-attributes poller-running \
  || echo "[setup]   posture check already exists"

echo "[setup] service policies (dial for the gateways, bind for ziti-host)..."
ziti edge create service-policy historian-dial Dial --service-roles '@historian' --identity-roles '#gateway' \
  --posture-check-roles '#poller-running' \
  || echo "[setup]   dial policy already exists"
# also applies the posture check to a dial policy created by an earlier run
ziti edge update service-policy historian-dial --posture-check-roles '#poller-running'
ziti edge create service-policy historian-bind Bind --service-roles '@historian' --identity-roles '#historian-host' \
  || echo "[setup]   bind policy already exists"

echo "[setup] done."
