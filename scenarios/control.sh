#!/bin/bash
# Control run: the same three phases as every scenario run, with no attack.
# Shows what normal behaviour looks like over the same span of time, and
# what a TrustEngine would flag when nothing is wrong.
#
#   scenarios/control.sh
source "$(dirname "$0")/lib.sh"

attack_start() { event action what="none: control run"; }
attack_stop() { :; }

run_scenario control none "no attack: normal behaviour in every phase"
