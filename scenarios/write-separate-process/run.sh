#!/bin/bash
# Scenario 2, compromised gateway writing Modbus registers: separate process.
#
# The attacker runs their own tool on the gateway, next to the polling
# loop, which keeps running untouched: the declared posture stays the same.
# The tool opens its own Modbus connection to the plc and writes a holding
# register at a fixed interval. Zeek sees the write function code from a
# new source port of the gateway's IP; osquery (a source on the gateway
# itself) sees an extra process and a second socket to port 502.
#
# modbus_writer.py is copied into the gateway at the start of the attack
# phase and stopped at its end; its output, one line per write, is
# logs/runs/<run id>.writes.log. The plc's holding registers are read
# before and after the attack phase, from inside the plc (not seen by
# Zeek). The written values stay in the plc after the run.
#
#   scenarios/write-separate-process/run.sh   # TARGET=gateway-b for the other one
source "$(dirname "$0")/../common/lib.sh"

TARGET="${TARGET:-gateway-a}"
WRITE_REGISTER="${WRITE_REGISTER:-1}"
WRITE_INTERVAL="${WRITE_INTERVAL:-30}"

attack_start() {
  event plc-registers values="$(plc_registers)"
  docker compose cp "$SCENARIO_DIR/modbus_writer.py" "$TARGET":/tmp/modbus_writer.py
  # outlives the phase on purpose (+60 s): attack_stop stops it
  docker compose exec -T "$TARGET" python /tmp/modbus_writer.py \
    "$((ATTACK + 60))" "$WRITE_INTERVAL" "$WRITE_REGISTER" \
    < /dev/null > "$RUNS_DIR/$RUN_ID.writes.log" &
  WRITER_JOB=$!
  event action what="modbus writer started" gateway="$TARGET" log="$RUN_ID.writes.log"
}

attack_stop() {
  docker compose exec -T "$TARGET" sh -c \
    'kill $(cat /tmp/modbus_writer.pid) 2>/dev/null; rm -f /tmp/modbus_writer.py /tmp/modbus_writer.pid' || true
  wait "${WRITER_JOB:-}" 2>/dev/null || true
  event action what="modbus writer stopped" gateway="$TARGET"
  event plc-registers values="$(plc_registers)"
}

run_scenario write-separate-process "$TARGET" \
  "scenario 2: a separate process on the gateway writes a holding register on its own Modbus connection" \
  write_register="$WRITE_REGISTER" write_interval_s="$WRITE_INTERVAL"
