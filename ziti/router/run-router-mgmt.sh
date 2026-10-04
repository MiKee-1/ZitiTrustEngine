#!/bin/bash
# Variant of /var/openziti/scripts/run-router.sh (openziti/quickstart image).
# Identical to the original, except for the "ziti edge login" line: the controller
# now serves the Edge Management API only on ZITI_CTRL_MGMT_PORT (1281), no longer on
# the same port as the Edge Client API (1280). The admin login used to create/enroll
# the router must therefore target that port. Everything else (router config, the
# ongoing operational connection to the controller) stays on the edge-client port
# (1280), same as the original: that's not a management operation.

set -o errexit
set -o nounset
set -o pipefail

. "${ZITI_SCRIPTS}/ziti-cli-functions.sh"

if [[ "${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS-}" == "" ]]; then export ZITI_CTRL_EDGE_ADVERTISED_ADDRESS="ziti-edge-controller"; fi
if [[ "${ZITI_CTRL_EDGE_ADVERTISED_PORT-}" == "" ]]; then export ZITI_CTRL_EDGE_ADVERTISED_PORT="1280"; fi
if [[ "${ZITI_ROUTER_PORT-}" == "" ]]; then export ZITI_ROUTER_PORT="3022"; fi
if [[ "${ZITI_ROUTER_ROLES}" == "" ]]; then export ZITI_ROUTER_ROLES="${ZITI_ROUTER_NAME}"; fi
ZITI_CTRL_MGMT_PORT="${ZITI_CTRL_MGMT_PORT:?ZITI_CTRL_MGMT_PORT not set}"

if [[ "${ZITI_ROUTER_NAME-}" != "" ]]; then
  _ZITI_ROUTER_NAME="${ZITI_ROUTER_NAME}"
  echo "_ZITI_ROUTER_NAME set to: ${_ZITI_ROUTER_NAME}"
fi

until [ -f "${ZITI_HOME}/ziti.env" ]
do
  sleep 1
done
sleep 1
. "${ZITI_HOME}/ziti.env"

_wait_for_controller

sleep 1

if [[ "${_ZITI_ROUTER_NAME}" != "" ]]; then
  export ZITI_ROUTER_NAME="${_ZITI_ROUTER_NAME}"
  echo "ZITI_ROUTER_NAME set to: ${ZITI_ROUTER_NAME}"
fi

_CONFIG_PATH="${ZITI_HOME}/${ZITI_ROUTER_NAME}.yaml"
trap '[[ -f "${_CONFIG_PATH}" ]] && mv "${_CONFIG_PATH}" "${_CONFIG_PATH}.err"' ERR

if [ ! -f "${_CONFIG_PATH}" ]; then
  echo "config has not been generated, generating config..."
  # <<< only difference from the original: login against the Edge Management API (1281) >>>
  "${ZITI_BIN_DIR-}/ziti" edge login "${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_MGMT_PORT}" -u "$ZITI_USER" -p "$ZITI_PWD" -y

  echo "----------  Creating edge-router ${ZITI_ROUTER_NAME}...."

  if [[ "$1" == "edge" ]]; then
    echo "CREATING EDGE ROUTER CONFIG: ${ZITI_ROUTER_NAME}"
    createEdgeRouterConfig "${ZITI_ROUTER_NAME}"
  fi
  if [[ "$1" == "wss" ]]; then
    echo "CREATING EDGE ROUTER WSS CONFIG: ${ZITI_ROUTER_NAME}"
    createEdgeRouterWssConfig "${ZITI_ROUTER_NAME}"
  fi
  if [[ "$1" == "fabric" ]]; then
    echo "CREATING FABRIC ROUTER CONFIG: ${ZITI_ROUTER_NAME}"
    createFabricRouterConfig "${ZITI_ROUTER_NAME}"
  fi
  if [[ "$1" == "private" ]]; then
    echo "CREATING PRIVATE ROUTER CONFIG: ${ZITI_ROUTER_NAME}"
    createPrivateRouterConfig "${ZITI_ROUTER_NAME}"
  fi

  if "${ZITI_BIN_DIR-}/ziti" edge list edge-routers "name = \"${ZITI_ROUTER_NAME}\"" --csv | grep -q "${ZITI_ROUTER_NAME}"; then
    echo "----------  Found existing edge-router ${ZITI_ROUTER_NAME}...."
  else
    "${ZITI_BIN_DIR}/ziti" edge create edge-router "${ZITI_ROUTER_NAME}" -o "${ZITI_HOME}/${ZITI_ROUTER_NAME}.jwt" -t -a "${ZITI_ROUTER_ROLES}"
    sleep 1
    echo "---------- Enrolling edge-router ${ZITI_ROUTER_NAME}...."
    "${ZITI_BIN_DIR}/ziti" router enroll "${ZITI_HOME}/${ZITI_ROUTER_NAME}.yaml" --jwt "${ZITI_HOME}/${ZITI_ROUTER_NAME}.jwt"
    echo ""
  fi
else
    echo " Found existing config file ${_CONFIG_PATH}, not creating a new config."
fi

unset ZITI_USER
unset ZITI_PWD

"${ZITI_BIN_DIR}/ziti" router run "${ZITI_HOME}/${ZITI_ROUTER_NAME}.yaml"
