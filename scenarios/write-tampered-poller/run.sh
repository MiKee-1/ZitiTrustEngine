#!/bin/bash
# Scenario 2, compromised gateway writing Modbus registers: tampered poller.
#
# The attacker edits the gateway's polling loop so that it also writes a
# holding register, on its own Modbus connection, and restarts it with the
# usual command. Executable, command line and declared posture stay the
# same, and osquery attributes the Modbus socket to the legitimate process:
# what gives it away is the write function code that Zeek sees on the
# poller's connection. The restart itself leaves a trace (new pid and
# start time, the old Modbus connection closed and a new one opened).
#
# At the start of the attack phase the poller is stopped, poller.py is
# moved to poller_orig.py and replaced by poller_tampered.py, and the poller
# is started again. At the end the tampered poller is stopped, poller.py is
# restored and the original started. The writes are recorded in
# logs/runs/<run id>.writes.log; the plc's holding registers are read
# before and after the attack phase, from inside the plc (not seen by Zeek).
# The written values stay in the plc after the run.
#
#   scenarios/write-tampered-poller/run.sh   # TARGET=gateway-b for the other one
source "$(dirname "$0")/../common/lib.sh"

TARGET="${TARGET:-gateway-a}"
WRITE_REGISTER="${WRITE_REGISTER:-1}"
WRITE_EVERY="${WRITE_EVERY:-3}"     # cycles: 30 s at the poller's 10 s

# stops the polling loop in the gateway and waits for its pid file to go
STOP_POLLER="kill \$(cat $POLLER_PID) 2>/dev/null; \
for i in \$(seq 50); do [ -e $POLLER_PID ] || break; sleep 0.1; done"

attack_start() {
  local t
  event plc-registers values="$(plc_registers)"
  docker compose cp "$SCENARIO_DIR/poller_tampered.py" "$TARGET":/tmp/poller_tampered.py
  t=$(lab_do "$TARGET" "$STOP_POLLER; rm -f /tmp/modbus-writes.log; \
    mv /app/poller.py /app/poller_orig.py; mv /tmp/poller_tampered.py /app/poller.py")
  event_at "$t" action what="polling loop stopped, poller.py replaced" gateway="$TARGET"
  # started as everywhere else (exec -d): see poller-stopped/run.sh
  t=$(lab_now)
  docker compose exec -d -e WRITE_REGISTER="$WRITE_REGISTER" -e WRITE_EVERY="$WRITE_EVERY" \
    "$TARGET" gateway-poller poller.py
  event_at "$t" action what="tampered polling loop started" gateway="$TARGET"
}

# also called on Ctrl+C, at any point of attack_start: restores poller.py
# only if it was replaced. The original is started again right away, before
# collecting the writes and reading the registers: every second without a
# poller is a gap in the polling rhythm caused by the script, not by the
# attack.
attack_stop() {
  local t
  t=$(lab_do "$TARGET" "$STOP_POLLER; \
    if [ -e /app/poller_orig.py ]; then mv /app/poller_orig.py /app/poller.py; fi; \
    rm -f /tmp/poller_tampered.py /app/__pycache__/poller_orig.*")
  event_at "$t" action what="tampered polling loop stopped, poller.py restored" gateway="$TARGET"
  t=$(lab_now)
  docker compose exec -d "$TARGET" gateway-poller poller.py
  event_at "$t" action what="polling loop started" gateway="$TARGET"
  docker compose cp "$TARGET":/tmp/modbus-writes.log "$RUNS_DIR/$RUN_ID.writes.log" || true
  docker compose exec -T "$TARGET" rm -f /tmp/modbus-writes.log || true
  event plc-registers values="$(plc_registers)"
}

run_scenario write-tampered-poller "$TARGET" \
  "scenario 2: the tampered polling loop writes a holding register on its own Modbus connection" \
  write_register="$WRITE_REGISTER" write_every_cycles="$WRITE_EVERY"
