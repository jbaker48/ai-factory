#!/usr/bin/env bash
# Tests for factory/bin/autopilot: resubmitted jobs, claims, --watch.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export AUTOPILOT_POLL_S=0

# mkjob <id> <bead> <stage> [<updated>]
mkjob() {
  mkdir -p "factory/jobs/$1"
  jq -n --arg id "$1" --arg b "$2" --arg s "$3" --arg u "${4:-2026-01-01T00:00:00Z}" \
    '{id:$id,bead:$b,stage:$s,updated:$u}' >"factory/jobs/$1/job.json"
}

# setup: a repo, a claude stub that merges the job named in its prompt (the
# first /factory resume <id> or adopt <bead>), and a next-bead that hands out
# $TEST_TMP/queue's lines one at a time.
setup() {
  R=$(mkrepo); cd "$R" || return
  rm -f "$TEST_TMP/queue" "$TEST_TMP/nb.n" "$TEST_TMP/claimed-during" "$STUBS/claude.calls"
  # shellcheck disable=SC2016 # the stub expands these when it runs
  stub claude '
p=$2
id=$(printf "%s" "$p" | sed -n "s|^/factory resume \([^ .]*\)\..*|\1|p")
if [ -z "$id" ]; then
  b=$(printf "%s" "$p" | sed -n "s|^/factory autopilot adopt \([^ .]*\)\..*|\1|p")
  id=$(jq -r --arg b "$b" "select(.bead == \$b) | .id" factory/jobs/*/job.json | tail -n 1)
fi
if [ -n "$id" ]; then
  [ -d "factory/jobs/$id/.resume-claim" ] && echo "$id" >>"$TEST_TMP/claimed-during"
  factory/bin/job-set "factory/jobs/$id/job.json" ".stage = \"${STUB_STAGE:-merged}\""
fi
echo "{\"session_id\":\"s\",\"total_cost_usd\":0}"'
  # shellcheck disable=SC2016 # the stub expands these when it runs
  printf '#!/usr/bin/env bash\necho x >>"%s/nb.n"\n%s\nl=$(head -n 1 "%s/queue" 2>/dev/null); [ -n "$l" ] && sed -i.bak 1d "%s/queue"; echo "$l"\n' \
    "$TEST_TMP" "${NB_HOOK:-:}" "$TEST_TMP" "$TEST_TMP" >factory/bin/next-bead
  printf '#!/usr/bin/env bash\nexit 0\n' >factory/bin/usage-record
}

test_resubmitted_before_queue() {
  setup
  mkjob 001-a bead-a resubmitted
  mkjob 002-q bead-q queued
  echo bead-q >"$TEST_TMP/queue"
  factory/bin/autopilot 1 >/dev/null 2>&1
  assert_contains "$(head -n 1 "$STUBS/claude.calls")" "/factory\\ resume\\ 001-a." "resumes the resubmitted job first"
  assert_eq "merged" "$(jq -r .stage factory/jobs/001-a/job.json)" "job merged"
  cd - >/dev/null || return
}

test_oldest_first() {
  setup
  mkjob 001-new b1 resubmitted 2026-03-01T00:00:00Z
  mkjob 002-old b2 resubmitted 2026-02-01T00:00:00Z
  factory/bin/autopilot 1 >/dev/null 2>&1
  assert_contains "$(head -n 1 "$STUBS/claude.calls")" "002-old" "oldest updated first"
  cd - >/dev/null || return
}

test_prompt_says_claimed() {
  setup
  mkjob 001-a bead-a resubmitted
  STUB_STAGE=build factory/bin/autopilot 1 >/dev/null 2>&1
  n=$(grep -c 'Claimed\\ for\\ you\\ by\\ autopilot' "$STUBS/claude.calls")
  assert_eq 3 "$n" "first resume and the later resumes all say claimed"
  assert_eq 3 "$(wc -l <"$TEST_TMP/claimed-during" | tr -d ' ')" "claim held during every session"
  cd - >/dev/null || return
}

test_adopted_job_resume_not_claimed() {
  setup
  mkjob 001-a bead-a queued
  echo bead-a >"$TEST_TMP/queue"
  STUB_STAGE=build factory/bin/autopilot 1 >/dev/null 2>&1
  assert_eq 0 "$(grep -c 'Claimed' "$STUBS/claude.calls")" "no claim text for adopted jobs"
  cd - >/dev/null || return
}

test_claim_skips_claimed() {
  setup
  mkjob 001-a bead-a resubmitted
  mkdir factory/jobs/001-a/.resume-claim
  factory/bin/autopilot 1 >/dev/null 2>&1
  assert_eq "no" "$([ -e "$STUBS/claude.calls" ] && echo yes || echo no)" "claimed job is not resumed"
  assert_eq "resubmitted" "$(jq -r .stage factory/jobs/001-a/job.json)" "untouched"
  assert_eq "yes" "$([ -d factory/jobs/001-a/.resume-claim ] && echo yes || echo no)" "foreign claim left alone"
  cd - >/dev/null || return
}

test_claim_removed_after() {
  setup
  mkjob 001-a bead-a resubmitted
  factory/bin/autopilot 1 >/dev/null 2>&1
  assert_eq "no" "$([ -e factory/jobs/001-a/.resume-claim ] && echo yes || echo no)" "claim removed"
  cd - >/dev/null || return
}

test_claim_removed_on_resume_cap() {
  setup
  mkjob 001-a bead-a resubmitted
  STUB_STAGE=build factory/bin/autopilot 1 >/dev/null 2>&1
  rc=$?
  assert_eq 1 "$rc" "cap exit"
  assert_eq "no" "$([ -e factory/jobs/001-a/.resume-claim ] && echo yes || echo no)" "claim removed on cap failure"
  cd - >/dev/null || return
}

test_claim_removed_on_term() {
  setup
  mkjob 001-a bead-a resubmitted
  # shellcheck disable=SC2016
  stub claude 'touch "$TEST_TMP/in-session"; sleep 1; echo "{\"session_id\":\"s\",\"total_cost_usd\":0}"'
  rm -f "$TEST_TMP/in-session"
  factory/bin/autopilot >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ ! -e "$TEST_TMP/in-session" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "no" "$([ -e factory/jobs/001-a/.resume-claim ] && echo yes || echo no)" "claim removed on TERM"
  cd - >/dev/null || return
}

test_dropped_is_end_state() {
  setup
  mkjob 001-a bead-a resubmitted
  STUB_STAGE=dropped factory/bin/autopilot 1 >/dev/null 2>&1
  assert_eq 1 "$(wc -l <"$STUBS/claude.calls" | tr -d ' ')" "one session, no resume"
  cd - >/dev/null || return
}

test_empty_queue_exits() {
  setup
  out=$(factory/bin/autopilot 2>&1); rc=$?
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$out" "queue empty" "says so"
  cd - >/dev/null || return
}

test_watch_count_bounds() {
  setup
  # the first empty poll creates a resubmitted job; --watch must pick it up
  # shellcheck disable=SC2016
  NB_HOOK='[ "$(wc -l <"'"$TEST_TMP"'/nb.n")" -ge 2 ] && [ ! -d factory/jobs/009-late ] && { mkdir -p factory/jobs/009-late; echo "{\"id\":\"009-late\",\"bead\":\"b9\",\"stage\":\"resubmitted\",\"updated\":\"2026-01-01T00:00:00Z\"}" >factory/jobs/009-late/job.json; }' \
    setup
  out=$(factory/bin/autopilot 1 --watch 2>&1); rc=$?
  assert_eq 0 "$rc" "exits after <count> jobs"
  assert_eq "merged" "$(jq -r .stage factory/jobs/009-late/job.json)" "late job picked up"
  assert_contains "$out" "009-late" "summary line"
  cd - >/dev/null || return
}

test_watch_keeps_polling_until_killed() {
  setup
  factory/bin/autopilot --watch >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ "$(cat "$TEST_TMP/nb.n" 2>/dev/null | wc -l | tr -d ' ')" -lt 3 ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  alive=$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq yes "$alive" "still running after 3 empty polls"
  cd - >/dev/null || return
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
