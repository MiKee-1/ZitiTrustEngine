#!/bin/bash
# Scenario 3, declared posture in order while osquery tells otherwise.
#
# The attacker stops the polling loop and runs a fake gateway-poller in its
# place: the same executable (gateway-poller, a copy of the interpreter) run
# as `gateway-poller -c "import time; time.sleep(...)"`, so the process
# posture check sees the same path and hash and keeps allowing the dial.
# Meanwhile attacker.py posts made-up readings to the historian with the
# standard interpreter (it can dial only because the fake poller satisfies
# the check). The declared posture stays perfect; what gives it away is the
# gap between declared and observed: osquery shows a different cmdline and no
# socket to port 502, Zeek stops seeing the gateway's Modbus reads, and the
# controller shows circuits with no reads behind them.
#
# To avoid a window in which the posture check would deny (no gateway-poller
# running, ~2-3 s, see the reference case), the fake poller is started
# before the real one is stopped, both in one command; at the end the real
# one is started and the fake one stopped, again in one command. The fake
# poller's pid is kept in /tmp/fake-poller.pid, not /run/poller.pid, so the
# real poller does not take it for a second instance of itself.
#
# The out-of-band Modbus write of scenario 2 does not happen here: the point
# is a client that declares a healthy posture while doing something else.
# The attacker only talks to the historian; its posts are recorded in
# logs/runs/<run id>.posts.log.
#
#   scenarios/fake-poller/run.sh        # TARGET=gateway-b for the other one
source "$(dirname "$0")/../common/lib.sh"

TARGET="${TARGET:-gateway-a}"
POST_INTERVAL="${POST_INTERVAL:-10}"   # match the poller's 10 s rhythm
FAKE_PID=/tmp/fake-poller.pid

# A fake gateway-poller: same executable as the real poller, so the same
# declared posture (path and hash), but it only sleeps. Started from a shell
# that exits right away (so PID 1 adopts it, as for the real poller) and told
# to sleep well past the attack phase; its pid, caught with $!, goes to
# FAKE_PID so attack_stop can kill it.
START_FAKE="gateway-poller -c 'import time; time.sleep($((ATTACK + 60)))' \
  < /dev/null > /dev/null 2>&1 & echo \$! > $FAKE_PID"

attack_start() {
  local t
  docker compose cp "$SCENARIO_DIR/attacker.py" "$TARGET":/tmp/attacker.py
  # fake poller up, then real poller down, in one command: a gateway-poller
  # is always running, so the posture never flips to false
  t=$(lab_do "$TARGET" "$START_FAKE; $STOP_POLLER")
  event_at "$t" action what="fake gateway-poller started, polling loop stopped" gateway="$TARGET"
  # outlives the phase on purpose (+60 s): attack_stop stops it
  docker compose exec -T "$TARGET" python /tmp/attacker.py \
    "$((ATTACK + 60))" "$POST_INTERVAL" \
    < /dev/null > "$RUNS_DIR/$RUN_ID.posts.log" &
  ATTACKER_JOB=$!
  event action what="attacker historian client started" gateway="$TARGET" log="$RUN_ID.posts.log"
}

# also called on Ctrl+C: stops the attacker, restarts the real poller and
# stops the fake one, in one command (same reason as above)
attack_stop() {
  local t
  docker compose exec -T "$TARGET" sh -c \
    'kill $(cat /tmp/attacker.pid) 2>/dev/null; rm -f /tmp/attacker.py /tmp/attacker.pid' || true
  wait "${ATTACKER_JOB:-}" 2>/dev/null || true
  event action what="attacker historian client stopped" gateway="$TARGET"
  t=$(lab_do "$TARGET" "$START_POLLER kill \$(cat $FAKE_PID) 2>/dev/null; rm -f $FAKE_PID")
  event_at "$t" action what="polling loop started, fake gateway-poller stopped" gateway="$TARGET"
}

run_scenario fake-poller "$TARGET" \
  "scenario 3: a fake gateway-poller keeps the declared posture in order while the attacker uses the historian" \
  post_interval_s="$POST_INTERVAL"
