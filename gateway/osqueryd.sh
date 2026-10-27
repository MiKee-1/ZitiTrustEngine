#!/bin/bash
# Starts the osquery daemon with the scheduled queries in osquery.conf.
# Started by entrypoint.sh when the gateway starts. By hand, after stopping
# it, from a shell that exits right away (so that PID 1 adopts it, as when
# the entrypoint starts it):
#
#   docker compose exec -T gateway-a sh -c 'bash osqueryd.sh < /dev/null > /dev/null 2>&1 &'
#
# Results go to logs/osquery/<gateway>/osqueryd.snapshots.log, one JSON line
# per query run with its timestamp; osqueryd's own status logs sit next to
# it. That directory is the only one of logs/osquery mounted into this
# gateway, at /logs/osquery. The pid file in /var/osquery stops a second
# daemon from starting.
#
# hostIdentifier is set to the gateway's name, which is self-declared: it
# comes from the same machine the data describes. logger_mode 0644 keeps
# the files written as root readable from the host.
set -euo pipefail
GATEWAY_ID="${GATEWAY_ID:?GATEWAY_ID not set}"
# osqueryd does not create its log directory, it exits if it is missing
mkdir -p /var/osquery /logs/osquery
exec osqueryd --flagfile=/app/osquery.flags \
  --logger_path=/logs/osquery \
  --specified_identifier="${GATEWAY_ID}"
