#!/bin/bash
# Exports the posture state of every gateway (identities with the "gateway"
# role) to logs/posture/<UTC time>.json: the last posture data each tunneler
# reported (process running or not, binary hash) and the controller's list
# of dial requests it denied, each with the check that failed, the expected
# and the reported value.
#
# A denied dial produces no entry in events.json nor in the controller's
# process log: on the controller side these two Management API endpoints
# are the only place it shows up. Neither has a ziti CLI command, so they
# are called with curl using the CLI's session token.
#
# Run from the repo root with the stack up, one file per export, all kept.
# Logs in with the admin credentials already in the controller container's
# environment (.env). Noise it leaves behind: a Default Admin apiSession in
# events.json, and "could not convert posture data ... got <nil>" ERROR
# lines in the controller's process log (posture types this lab doesn't
# use: domain, mac, os).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs/posture
out="logs/posture/$(date -u +%Y%m%dT%H%M%SZ).json"
trap 'rm -f "${out}.tmp"' EXIT
docker compose exec -T ziti-controller bash -c '
  set -euo pipefail
  export PATH=/var/openziti/ziti-bin:$PATH
  mgmt=https://ziti-controller:1281
  ziti edge login "$mgmt" -u "$ZITI_USER" -p "$ZITI_PWD" -y >/dev/null
  # the v2 CLI logs in via OIDC and saves a bearer access token; older
  # versions saved a legacy zt-session token instead
  cli_cfg=~/.config/ziti/ziti-cli.json
  token=$(jq -r ".edgeIdentities.default.apiSession.oidcAccessToken // empty" "$cli_cfg")
  if [ -n "$token" ]; then
    auth="Authorization: Bearer $token"
  else
    auth="zt-session: $(jq -r .edgeIdentities.default.token "$cli_cfg")"
  fi
  api() { curl -sfk -H "$auth" "$mgmt/edge/management/v1/$1"; }
  ziti edge list identities "anyOf(roleAttributes) = \"gateway\" limit none" -j \
    | jq -r ".data[] | \"\(.id) \(.name)\"" \
    | while read -r id name; do
        jq -n --arg id "$id" --arg name "$name" \
          --argjson posture "$(api "identities/$id/posture-data" | jq .data)" \
          --argjson failed "$(api "identities/$id/failed-service-requests" | jq .data)" \
          "{id: \$id, name: \$name, postureData: \$posture, failedServiceRequests: \$failed}"
      done \
    | jq -s "{exportedAt: (now | todate), identities: .}"
' > "${out}.tmp"
mv "${out}.tmp" "${out}"
echo "written ${out}"
