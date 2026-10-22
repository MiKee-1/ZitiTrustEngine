#!/bin/bash
# Reference case: the gateway's polling loop stops. OpenZiti handles this on
# its own: the historian's dial policy requires the process posture check
# poller-running, so once the tunneler reports gateway-poller as not
# running the gateway's dials are denied.
#
# With the loop stopped nothing on the gateway dials anymore, and the
# denial would never show. So probe.py is copied into the gateway at the
# start of the attack phase and dials the historian every PROBE_INTERVAL s
# until its end; the loop is stopped PROBE_LEAD s later. The probe's output,
# logs/runs/<run id>.probe.log, gives the last allowed and the first denied
# dial. At the end of the phase the loop is started again (its first cycle
# is denied, as on every start).
#
#   scenarios/poller-stopped/run.sh        # TARGET=gateway-b for the other one
source "$(dirname "$0")/../common/lib.sh"

TARGET="${TARGET:-gateway-a}"
PROBE_INTERVAL="${PROBE_INTERVAL:-1}"
PROBE_LEAD="${PROBE_LEAD:-10}"

attack_start() {
  local t
  docker compose cp "$SCENARIO_DIR/probe.py" "$TARGET":/tmp/probe.py
  # outlives the phase on purpose (+60 s): attack_stop stops it
  docker compose exec -T "$TARGET" python /tmp/probe.py \
    "$((PROBE_LEAD + ATTACK + 60))" "$PROBE_INTERVAL" \
    < /dev/null > "$RUNS_DIR/$RUN_ID.probe.log" &
  PROBE_JOB=$!
  event action what="probe started" gateway="$TARGET" log="$RUN_ID.probe.log"
  sleep "$PROBE_LEAD"
  t=$(lab_do "$TARGET" "kill \$(cat $POLLER_PID)")
  event_at "$t" action what="polling loop stopped" gateway="$TARGET"
}

attack_stop() {
  local t
  docker compose exec -T "$TARGET" sh -c \
    'kill $(cat /tmp/probe.pid) 2>/dev/null; rm -f /tmp/probe.py /tmp/probe.pid' || true
  wait "${PROBE_JOB:-}" 2>/dev/null || true
  event action what="probe stopped" gateway="$TARGET"
  # started as everywhere else (exec -d), not from a shell inside lab_do:
  # osquery would see a different parent process. Its exact start time is
  # in its own log.
  t=$(lab_now)
  docker compose exec -d "$TARGET" gateway-poller poller.py
  event_at "$t" action what="polling loop started" gateway="$TARGET"
}

run_scenario poller-stopped "$TARGET" \
  "reference case: polling loop stopped, the process posture check denies the dials" \
  probe_interval_s="$PROBE_INTERVAL" probe_lead_s="$PROBE_LEAD"
