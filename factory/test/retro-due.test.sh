#!/usr/bin/env bash
# Tests for factory/bin/retro-due.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RD="$FACTORY_SRC/bin/retro-due"

# job <json>: a fresh job folder whose job.json is <json>; sets J.
job() {
  J=$(mktemp -d "$TEST_TMP/j.XXXXXX")
  echo "$1" >"$J/job.json"
}

# clean <stage> [<jq object merged over a clean job>]: a job at <stage> with no signals.
clean() {
  job "$(jq -n -c --arg s "$1" --argjson x "${2:-{\}}" \
    '{stage:$s,round:1,reworks:0,respecs:0,tasks:[{runs:1}]} + $x')"
}

test_clean_merged_not_due() {
  clean merged
  assert_exit 1 "clean merged job" -- "$RD" "$J"
}

test_rounds_due() {
  clean merged '{"round":8}'
  assert_exit 0 "round 8" -- "$RD" "$J"
}

test_rework_respec_due() {
  clean merged '{"reworks":1}'
  assert_exit 0 "reworks" -- "$RD" "$J"
  clean merged '{"respecs":1}'
  assert_exit 0 "respecs" -- "$RD" "$J"
}

test_task_rerun_due() {
  clean merged '{"tasks":[{"runs":1},{"runs":2}]}'
  assert_exit 0 "task ran twice" -- "$RD" "$J"
}

test_old_job_files_due() {
  clean merged
  : >"$J/rework-1.md"
  assert_exit 0 "rework file" -- "$RD" "$J"
  clean merged
  : >"$J/decision-round1.md"
  assert_exit 0 "decision-round file" -- "$RD" "$J"
}

test_escalate_decision_due() {
  clean merged
  printf 'ESCALATE\nwhy\n' >"$J/decision.md"
  assert_exit 0 "ESCALATE decision" -- "$RD" "$J"
  clean merged
  printf 'APPROVE\n' >"$J/decision.md"
  assert_exit 1 "other decision" -- "$RD" "$J"
}

test_not_end_state() {
  clean needs-human '{"round":8}'
  assert_exit 1 "needs-human" -- "$RD" "$J"
}

test_dropped_due() {
  clean dropped '{"reworks":1}'
  assert_exit 0 "dropped" -- "$RD" "$J"
}

test_already_has_retro() {
  clean merged '{"round":8}'
  : >"$J/retro.md"
  assert_exit 1 "retro exists" -- "$RD" "$J"
}

test_usage() {
  assert_exit 2 "no argument" -- "$RD"
  J=$(mktemp -d "$TEST_TMP/j.XXXXXX")
  assert_exit 2 "no job.json" -- "$RD" "$J"
  job 'not json'
  assert_exit 2 "unreadable job.json" -- "$RD" "$J"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
