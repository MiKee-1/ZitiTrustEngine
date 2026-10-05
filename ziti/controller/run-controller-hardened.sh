#!/bin/bash
# Variant of /var/openziti/scripts/run-controller.sh (openziti/quickstart image).
# Does exactly the same things as the original script, with one extra step:
# right after generating the controller's config.yaml, it rewrites it to split
# the web listener in two:
#   - edge-client-api     -> exposes ONLY edge-client/edge-oidc, on 0.0.0.0 (must stay
#                             reachable from both the gateways on the ot network and
#                             whoever binds a service)
#   - edge-management-api -> exposes edge-management/fabric, bound ONLY on
#                             ZITI_CTRL_MGMT_BIND (normally the controller's IP on the
#                             "it" network): from the ot network this port is not even
#                             reachable at the TCP level.
#
# Reason: in the default generated config, both APIs share the same bind point, so
# anyone who can reach the edge-client port (needed for dial) can also reach the
# controller's management surface (identities, policies, services), even though
# authentication then blocks them. Here we separate them at the network level, not
# just by credentials.
#
# The same rewrite also adds an "events" section, so the controller writes a
# structured, file-backed log of circuit/session/apiSession events (one of the
# three log sources for the TrustEngine). Written to /events/events.json, a
# bind mount (see docker-compose.yml) so it's readable from the host directly.
#
# Also fixes a real bug found by actually restarting this container (not just
# recreating it after a full `down -v`): the original script's "already
# initialized" check looks for a file, access-control.init, that nothing -
# not this script, not ziti-cli-functions.sh - ever creates. So every restart
# took the "not initialized" branch again, including a call to
# `createControllerConfig`, which prompts for overwrite permission when the
# config file already exists - a prompt that can't be answered with no TTY,
# so the container just exited. Using the real config file's own existence as
# the "already initialized" signal instead fixes this for good.

set -e

ASCI_RESTORE='\033[0m'
ASCI_RED='\033[00;31m'

function RED {
  echo "${ASCI_RED}${1-}${ASCI_RESTORE}"
}

function hardenControllerConfig {
  local cfg="${ZITI_HOME}/${ZITI_CTRL_NAME}.yaml"
  local client_addr="${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_EDGE_ADVERTISED_PORT}"
  local mgmt_bind="${ZITI_CTRL_MGMT_BIND:?ZITI_CTRL_MGMT_BIND not set: not rewriting the config, the controller would start with client+management on the same bind point}"
  # "address" is only used for TLS validation / response content and must match a SAN
  # of the controller's certificate (the default ones: ziti-controller, ziti, localhost,
  # 127.0.0.1). It doesn't have to match "interface": it's "interface" (the real IP,
  # only on the it network) that determines where the socket is actually reachable from.
  local mgmt_address="${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_MGMT_PORT:-1281}"

  echo "hardening: ${cfg} -> edge-client on 0.0.0.0:${ZITI_CTRL_EDGE_ADVERTISED_PORT}, edge-management bind on ${mgmt_bind} (address ${mgmt_address})"

  awk '/^web:/{exit} {print}' "${cfg}" > "${cfg}.tmp"
  cat >> "${cfg}.tmp" <<EOF
web:
  - name: edge-client-api
    bindPoints:
      - interface: 0.0.0.0:${ZITI_CTRL_EDGE_ADVERTISED_PORT}
        address: ${client_addr}
    identity:
      ca:          "${ZITI_PKI_EDGE_CA}"
      key:         "${ZITI_PKI_EDGE_KEY}"
      server_cert: "${ZITI_PKI_EDGE_SERVER_CERT}"
      cert:        "${ZITI_PKI_EDGE_CERT}"
    options:
      idleTimeout: 5000ms
      readTimeout: 5000ms
      writeTimeout: 100000ms
      minTLSVersion: TLS1.2
      maxTLSVersion: TLS1.3
    apis:
      - binding: edge-client
        options: { }
      - binding: edge-oidc
        options: { }
  - name: edge-management-api
    bindPoints:
      - interface: ${mgmt_bind}
        address: ${mgmt_bind}
    identity:
      ca:          "${ZITI_PKI_EDGE_CA}"
      key:         "${ZITI_PKI_EDGE_KEY}"
      server_cert: "${ZITI_PKI_EDGE_SERVER_CERT}"
      cert:        "${ZITI_PKI_EDGE_CERT}"
    options:
      idleTimeout: 5000ms
      readTimeout: 5000ms
      writeTimeout: 100000ms
      minTLSVersion: TLS1.2
      maxTLSVersion: TLS1.3
    apis:
      - binding: edge-management
        options: { }
      - binding: fabric
        options: { }

events:
  jsonLogger:
    subscriptions:
      - type: fabric.circuits
        include:
          - created
          - deleted
      - type: edge.sessions
        include:
          - created
          - deleted
      - type: edge.apiSessions
        include:
          - created
          - deleted
      # "connect" is deliberately left out: it logs every client API call
      # (~3 events every 10s per identity, ~26k/day each) and the TrustEngine's
      # scenarios only need the IP at login (apiSessions) plus presence (sdk).
      - type: sdk
    handler:
      type: file
      format: json
      path: /events/events.json
EOF
  mv "${cfg}.tmp" "${cfg}"
}

if [[ "${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS-}" == "" ]]; then export ZITI_CTRL_EDGE_ADVERTISED_ADDRESS="ziti-edge-controller"; fi
if [[ "${ZITI_CTRL_NAME-}" == "" ]]; then export ZITI_CTRL_NAME="${ZITI_NETWORK}-controller"; fi

. "${ZITI_SCRIPTS}/ziti-cli-functions.sh"

controller_cfg="${ZITI_HOME}/${ZITI_CTRL_NAME}.yaml"

if [ ! -f "${controller_cfg}" ]; then
  echo "${controller_cfg} not found: first-time initialization."
  setupEnvironment
  persistEnvironmentValues
  . "${ZITI_HOME}/ziti.env"

  createPki
  createControllerConfig
  hardenControllerConfig

  "${ZITI_BIN_DIR}/ziti" controller edge init "${controller_cfg}" -u "${ZITI_USER}" -p "${ZITI_PWD}"
  if [[ "$?" != 0 ]]; then
    echo -e "$(RED "  --- There was an error while initializing the controller ---")"
    exit 1
  fi
else
  echo "${controller_cfg} already exists: already initialized, just starting the process."
  . "${ZITI_HOME}/ziti.env"
  # re-applied on every start (it's idempotent: it rewrites everything from
  # "web:" down), so changes to the web/events sections take effect on a
  # plain restart, without a `down -v` that would wipe the PKI.
  hardenControllerConfig
fi

echo "controller initialized. unsetting ZITI_USER/ZITI_PWD from env"
unset ZITI_USER
unset ZITI_PWD

mkdir -p "$ZITI_HOME/db"

"${ZITI_BIN_DIR}/ziti" controller run ${ZITI_VERBOSE:+--verbose} "${controller_cfg}"
