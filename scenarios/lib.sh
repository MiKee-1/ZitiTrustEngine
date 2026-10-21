#!/bin/bash
# Shared code for the scenario runs, sourced by the scripts next to it.
#
# A run has three timed phases: normal-before, attack, normal-after. The
# scenario script defines attack_start and attack_stop and calls
# run_scenario, which:
#   - checks that the lab is up (it never starts or stops the stack), starts
#     the polling loop and osqueryd on both gateways if they are not
#     running, and waits for each gateway's first successful post;
#   - exports the identity names before the first phase and the posture
#     data after the last one (analysis/), outside the phases: both log in
#     as admin on the controller;
#   - writes the ground truth of the run to logs/runs/<run id>.jsonl, one
#     JSON line per event (phase boundaries, attack actions) with its UTC
#     time taken from the lab's own clock, inside a container, so that it
#     lines up with the log sources.
#
# The ground truth is the label the TrustEngine will be checked against,
# not one of its sources.
#
# Durations in seconds, from the environment: NORMAL_BEFORE, ATTACK and
# NORMAL_AFTER (default 300, 600, 300). Ctrl+C during a run calls
# attack_stop if the attack is in progress and records the run as aborted.
#
# After a run: stop the lab and archive logs/, so that each run has its own
# set of logs.

set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: pass /paths to docker untouched
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NORMAL_BEFORE="${NORMAL_BEFORE:-300}"
ATTACK="${ATTACK:-600}"
NORMAL_AFTER="${NORMAL_AFTER:-300}"

GATEWAYS="gateway-a gateway-b"
SERVICES="ziti-controller ziti-router ziti-host historian plc zeek $GATEWAYS"
POLLER_PID=/run/poller.pid
OSQUERY_PID=/var/osquery/osqueryd.pidfile
RUNS_DIR=logs/runs
IN_ATTACK=0

DATE_MS="date -u +%Y-%m-%dT%H:%M:%S.%3NZ"

# UTC time from the lab's clock, in milliseconds
lab_now() {
  docker compose exec -T plc $DATE_MS | tr -d '\r'
}

# lab_do <service> <command>: runs the command in that container and prints
# the lab time taken right before it, in the same exec. For the actions
# whose time matters: an event recorded afterwards would be late by the
# duration of a docker exec (~0.5 s).
lab_do() {
  docker compose exec -T "$1" sh -c "$DATE_MS; $2" | tr -d '\r' | head -n 1
}

# event <name> [key=value ...]: appends one line to the ground truth file,
# timed now
event() {
  event_at "$(lab_now)" "$@"
}

# event_at <time> <name> [key=value ...]: same, with a time taken earlier
event_at() {
  local line kv v
  line="{\"t\":\"$1\",\"run\":\"$RUN_ID\",\"event\":\"$2\""
  shift 2
  for kv in "$@"; do
    v=${kv#*=}; v=${v//\\/\\\\}; v=${v//\"/\\\"}
    line+=",\"${kv%%=*}\":\"$v\""
  done
  line+="}"
  echo "$line" >> "$RUN_FILE"
  echo "  $line"
}

# running <gateway> <pid file>: true if that process is alive in the gateway
running() {
  docker compose exec -T "$1" sh -c "kill -0 \$(cat $2 2>/dev/null) 2>/dev/null"
}

# waits until the last line of the gateway's poller log is a successful post
wait_post_ok() {
  local f="logs/poller/$1/poller-$1.log" i
  for i in $(seq 30); do
    tail -n 1 "$f" 2>/dev/null | grep -q ' post=201 ' && return 0
    sleep 2
  done
  echo "$1: no successful post in 60 s, see $f" >&2
  exit 1
}

preflight() {
  local up s g
  up=$(docker compose ps --status running --services | tr -d '\r')
  for s in $SERVICES; do
    grep -qx "$s" <<<"$up" || { echo "$s is not running: start the lab first" >&2; exit 1; }
  done
  for g in $GATEWAYS; do
    if ! running "$g" "$OSQUERY_PID"; then
      echo "$g: osqueryd not running, starting it (in the background)"
      docker compose exec -d "$g" bash osqueryd.sh
    fi
    if ! running "$g" "$POLLER_PID"; then
      echo "$g: polling loop not running, starting it (in the background)"
      docker compose exec -d "$g" gateway-poller poller.py
    fi
  done
  for g in $GATEWAYS; do wait_post_ok "$g"; done
}

# phase_wait <seconds>: sleeps, telling when the wait ends
phase_wait() {
  echo "  waiting $1 s, until ~$(date -u -d "+$1 seconds" +%H:%M:%S) UTC"
  sleep "$1"
}

on_abort() {
  trap - INT TERM
  echo "interrupted"
  if [ "$IN_ATTACK" = 1 ]; then
    attack_stop || true
  fi
  event run-aborted
  exit 130
}

# run_scenario <scenario> <target gateway or "none"> <description> [key=value ...]
# Extra key=value pairs are the scenario's parameters, recorded in run-start.
run_scenario() {
  local scenario=$1 target=$2 description=$3
  shift 3
  preflight
  mkdir -p "$RUNS_DIR"
  RUN_ID="$(lab_now | tr -d ':-' | cut -c1-15)Z-$scenario"
  RUN_FILE="$RUNS_DIR/$RUN_ID.jsonl"
  echo "run $RUN_ID, ground truth in $RUN_FILE"

  # the code version that produced this run's logs; dirty=yes if the
  # working tree had uncommitted changes
  local commit dirty=no
  commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
  [ -z "$(git status --porcelain 2>/dev/null)" ] || dirty=yes

  event run-start scenario="$scenario" target="$target" description="$description" \
    commit="$commit" dirty="$dirty" \
    normal_before_s="$NORMAL_BEFORE" attack_s="$ATTACK" normal_after_s="$NORMAL_AFTER" "$@"
  analysis/export_identities.sh
  event identities-exported
  trap on_abort INT TERM

  event phase-start phase=normal-before
  phase_wait "$NORMAL_BEFORE"
  event phase-end phase=normal-before

  event phase-start phase=attack
  IN_ATTACK=1
  attack_start
  phase_wait "$ATTACK"
  attack_stop
  IN_ATTACK=0
  event phase-end phase=attack

  event phase-start phase=normal-after
  phase_wait "$NORMAL_AFTER"
  event phase-end phase=normal-after

  trap - INT TERM
  analysis/posture_status.sh
  event posture-exported
  event run-end
  echo "done: stop the lab and archive logs/ before the next run"
}
