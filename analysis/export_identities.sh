#!/bin/bash
# Exports the controller's identity list to logs/identities/<UTC time>.json,
# which ip_identity.py uses to print identity names instead of raw ids.
# One file per export, all kept: a `down -v` recreates every identity with a
# new id, so older events can only be named from an export taken before it.
# Run from the repo root with the stack up. Logs in with the admin
# credentials already in the controller container's environment (.env).
# Note: the login itself shows up in events.json as a Default Admin apiSession.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs/identities
out="logs/identities/$(date -u +%Y%m%dT%H%M%SZ).json"
docker compose exec -T ziti-controller bash -c \
  '/var/openziti/ziti-bin/ziti edge login https://ziti-controller:1281 -u "$ZITI_USER" -p "$ZITI_PWD" -y >/dev/null &&
   /var/openziti/ziti-bin/ziti edge list identities "true limit none" -j' > "${out}.tmp"
mv "${out}.tmp" "${out}"
echo "written ${out}"
