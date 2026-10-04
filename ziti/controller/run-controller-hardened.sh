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

set -e

ziti_controller_cfg="${ZITI_HOME}/ziti-edge-controller.yaml"

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
EOF
  mv "${cfg}.tmp" "${cfg}"
}

if [[ "${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS-}" == "" ]]; then export ZITI_CTRL_EDGE_ADVERTISED_ADDRESS="ziti-edge-controller"; fi
if [[ "${ZITI_CTRL_NAME-}" == "" ]]; then export ZITI_CTRL_NAME="${ZITI_NETWORK}-controller"; fi

. "${ZITI_SCRIPTS}/ziti-cli-functions.sh"

if [ ! -f "${ZITI_HOME}/access-control.init" ]; then
  echo "system has not been initialized. initializing..."
  setupEnvironment
  persistEnvironmentValues
  . "${ZITI_HOME}/ziti.env"

  if [ ! -f "${ZITI_HOME}/access-control.init" ]; then
    setupEnvironment
    persistEnvironmentValues
  else
    echo "system has been initialized already. just starting the process"
  fi
  createPki
  if [ ! -f "${ziti_controller_cfg}" ]; then
    echo " "
    echo "${ziti_controller_cfg} doesn't exist. Generating config file"
    echo " "
    createControllerConfig
  else
    echo " "
    echo "${ziti_controller_cfg} exists. Not overwriting"
    echo " "
  fi

  hardenControllerConfig

  "${ZITI_BIN_DIR}/ziti" controller edge init "${ZITI_HOME}/${ZITI_CTRL_NAME}.yaml" -u "${ZITI_USER}" -p "${ZITI_PWD}"
  if [[ "$?" != 0 ]]; then
    echo -e "$(RED "  --- There was an error while initializing the controller ---")"
    exit 1
  fi
else
  echo "system has been initialized. starting the process."
  . "${ZITI_HOME}/ziti.env"
fi

echo "controller initialized. unsetting ZITI_USER/ZITI_PWD from env"
unset ZITI_USER
unset ZITI_PWD

mkdir -p "$ZITI_HOME/db"

"${ZITI_BIN_DIR}/ziti" controller run ${ZITI_VERBOSE:+--verbose} "${ZITI_HOME}/${ZITI_CTRL_NAME}.yaml"
