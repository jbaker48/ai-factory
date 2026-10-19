#!/usr/bin/env bash
# Tests for factory/bin/autopilot: resubmitted jobs, claims, --watch.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export AUTOPILOT_POLL_S=0
unset BEADS_ACTOR BD_ACTOR

# mkjob <id> <bead> <stage> [<updated>]
mkjob() {
  mkdir -p "factory/jobs/$1"
  jq -n --arg id "$1" --arg b "$2" --arg s "$3" --arg u "${4:-2026-01-01T00:00:00Z}" \
    '{id:$id,bead:$b,stage:$s,updated:$u}' >"factory/jobs/$1/job.json"
}

# bdstub: a bd modelled on bd 1.3.0. $TEST_TMP/claims/<bead> holds the
# assignee. `update --claim` succeeds for nobody or the same actor (as real bd
# does) and fails for another; `update --if-assignee <a> ...` is a
# compare-and-set that exits 13 on a mismatch (an O_EXCL create for ''), and
# `--assignee ''` clears the assignee. `show --json` prints the assignee. It
# logs BEADS_ACTOR.
bdstub() {
  # shellcheck disable=SC2016 # the stub expands these when it runs
  stub bd '
echo "${BEADS_ACTOR:-}" >>"$TEST_TMP/actors"
cmd=$1 b=${2:-}
shift 2
claim="" assignee="" ifa="" ifaset=""
while [ $# -gt 0 ]; do
  case $1 in
    --claim) claim=1 ;;
    --assignee) assignee=$2; shift ;;
    --if-assignee) ifa=$2; ifaset=1; shift ;;
    --status | --if-status) shift ;;
  esac
  shift
done
f="$TEST_TMP/claims/$b"
case $cmd in
  show) jq -n --arg a "$(cat "$f" 2>/dev/null)" "[{assignee: (if \$a == \"\" then null else \$a end)}]" ;;
  update)
    if [ -n "$claim" ]; then
      cur=$(cat "$f" 2>/dev/null)
      [ -z "$cur" ] || [ "$cur" = "${BEADS_ACTOR:-}" ] || { echo "already claimed by $cur" >&2; exit 1; }
      echo "${BEADS_ACTOR:-}" >"$f"
    elif [ -n "$ifaset" ]; then
      if [ -z "$ifa" ]; then
        (set -o noclobber; echo "$assignee" >"$f") 2>/dev/null || { echo "assignee mismatch" >&2; exit 13; }
      else
        [ "$(cat "$f" 2>/dev/null)" = "$ifa" ] || { echo "assignee mismatch" >&2; exit 13; }
        if [ -n "$assignee" ]; then echo "$assignee" >"$f"; else rm -f "$f"; fi
      fi
    fi ;;
esac
exit 0'
}

# setup: a repo, a claude stub that merges the job named in its prompt (the
# first /factory resume <id> or adopt <bead>), and a next-bead that hands out
# $TEST_TMP/queue's lines one at a time.
setup() {
  R=$(mkrepo); cd "$R" || return
  rm -rf "$TEST_TMP/queue" "$TEST_TMP/nb.n" "$TEST_TMP/claimed-during" "$STUBS/claude.calls" \
    "$TEST_TMP/claims" "$TEST_TMP/actors" "$TEST_TMP/active" "$TEST_TMP/conc" "$TEST_TMP/ended" "$STUBS/bd.calls"
  mkdir -p "$TEST_TMP/claims" "$TEST_TMP/active"
  bdstub
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
  assert_eq 0 "$(grep '^-p /factory\\ resume' "$STUBS/claude.calls" | grep -c 'Claimed')" "no claim text in an adopted job's resumes"
  assert_eq 2 "$(grep -c '^-p /factory\\ resume' "$STUBS/claude.calls")" "two resumes ran"
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

# pool: setup, then a claude stub that marks itself active, records how many
# sessions were active at once, sleeps $STUB_SLEEP (default 1) and merges the
# job, and a next-bead that prints the first bead of $TEST_TMP/beads not in
# FACTORY_EXCLUDE_BEADS. It ignores claims, so two workers race for a bead.
pool() {
  setup
  rm -f "$TEST_TMP/beads"
  # shellcheck disable=SC2016 # the stub expands these when it runs
  stub claude '
echo "${BEADS_ACTOR:-}" >>"$TEST_TMP/session-actors"
b=$(printf "%s" "$2" | sed -n "s|^/factory autopilot adopt \([^ .]*\)\..*|\1|p")
id=$(jq -r --arg b "$b" "select(.bead == \$b) | .id" factory/jobs/*/job.json | tail -n 1)
r=$(printf "%s" "$2" | sed -n "s|^/factory resume \([^ .]*\)\..*|\1|p")
[ -n "$r" ] && id=$r b=$r
touch "$TEST_TMP/active/$b"
find "$TEST_TMP/active" -type f | wc -l | tr -d " " >>"$TEST_TMP/conc"
sleep "${STUB_SLEEP:-1}"
rm -f "$TEST_TMP/active/$b"
echo "$b" >>"$TEST_TMP/ended"
[ -n "$id" ] && factory/bin/job-set "factory/jobs/$id/job.json" ".stage = \"merged\""
echo "{\"session_id\":\"s\",\"total_cost_usd\":0}"'
  # shellcheck disable=SC2016 # the stub expands these when it runs
  printf '#!/usr/bin/env bash\nsleep "${NB_SLEEP:-0}"\nfor b in $(cat "%s/beads" 2>/dev/null); do case " ${FACTORY_EXCLUDE_BEADS:-} " in *" $b "*) ;; *) echo "$b"; exit 0 ;; esac; done\n' \
    "$TEST_TMP" >factory/bin/next-bead
  rm -f "$TEST_TMP/session-actors"
}

# beads <n>: queues bead-1..bead-<n>, each with a queued job.
beads() {
  local i
  for i in $(seq 1 "$1"); do
    echo "bead-$i" >>"$TEST_TMP/beads"
    mkjob "00$i-j" "bead-$i" queued
  done
}

maxconc() { sort -n "$TEST_TMP/conc" | tail -n 1; }

test_two_workers_run_concurrently() {
  pool; beads 2
  factory/bin/autopilot --jobs 2 >/dev/null 2>&1
  assert_eq 2 "$(maxconc)" "two sessions overlap"
  assert_eq merged "$(jq -r .stage factory/jobs/002-j/job.json)" "second job merged"
  cd - >/dev/null || return
}

test_no_double_claim() {
  pool; beads 1
  # both workers get bead-1 from next-bead before either claims it
  NB_SLEEP=0.3 factory/bin/autopilot --jobs 2 >/dev/null 2>&1
  assert_eq 1 "$(wc -l <"$STUBS/claude.calls" | tr -d ' ')" "exactly one session for one bead"
  cd - >/dev/null || return
}

test_no_double_claim_resubmitted() {
  pool
  mkjob 001-a bead-a resubmitted
  factory/bin/autopilot --jobs 3 >/dev/null 2>&1
  assert_eq 1 "$(wc -l <"$STUBS/claude.calls" | tr -d ' ')" "exactly one session for one resubmitted job"
  cd - >/dev/null || return
}

test_count_across_workers() {
  pool; beads 5
  out=$(factory/bin/autopilot --jobs 2 3 2>&1)
  assert_eq 3 "$(wc -l <"$STUBS/claude.calls" | tr -d ' ')" "exactly 3 jobs"
  assert_eq 3 "$(grep -c ' merged, ' <<<"$out")" "3 job lines"
  cd - >/dev/null || return
}

test_jobs_default_one() {
  pool; beads 3
  STUB_SLEEP=0.3 factory/bin/autopilot >/dev/null 2>&1
  assert_eq 3 "$(wc -l <"$STUBS/claude.calls" | tr -d ' ')" "all 3 jobs ran"
  assert_eq 1 "$(maxconc)" "never more than one session at once"
  cd - >/dev/null || return
}

test_jobs_setting() {
  pool; beads 2
  echo '{"jobs":2}' >factory/settings.json
  factory/bin/autopilot >/dev/null 2>&1
  assert_eq 2 "$(maxconc)" "jobs setting runs two at once"
  cd - >/dev/null || return
}

test_bad_jobs() {
  pool
  assert_exit 2 "--jobs 0 is a usage error" -- factory/bin/autopilot --jobs 0
  assert_exit 2 "--jobs x is a usage error" -- factory/bin/autopilot --jobs x
  cd - >/dev/null || return
}

test_prefixed_output() {
  pool; beads 2
  out=$(factory/bin/autopilot --jobs 2 2>&1)
  assert_contains "$out" "[001-j] " "first job prefixed"
  assert_contains "$out" "[002-j] " "second job prefixed"
  assert_eq "" "$(grep -v -e '^\[' -e '^autopilot: ' <<<"$out")" "every line is prefixed"
  assert_eq "" "$(grep '^autopilot: ' <<<"$out" | grep -v 'queue empty')" "only the queue line is unprefixed"
  cd - >/dev/null || return
}

test_interrupt_lists_in_flight() {
  pool; beads 2
  STUB_SLEEP=2 factory/bin/autopilot --jobs 2 >"$TEST_TMP/out" 2>&1 &
  pid=$!
  i=0
  while [ "$(find "$TEST_TMP/active" -type f | wc -l | tr -d ' ')" -lt 2 ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?
  out=$(cat "$TEST_TMP/out")
  assert_eq 130 "$rc" "exit 130"
  assert_contains "$out" "In flight:" "lists the jobs in flight"
  assert_contains "$out" "001-j (/factory resume 001-j)" "first job and its resume command"
  assert_contains "$out" "002-j (/factory resume 002-j)" "second job and its resume command"
  sleep 2.2
  assert_eq "no" "$([ -e "$TEST_TMP/ended" ] && echo yes || echo no)" "sessions were killed, not left running"
  cd - >/dev/null || return
}

test_actor_exported() {
  pool; beads 1
  factory/bin/autopilot >/dev/null 2>&1
  assert_eq factory-autopilot "$(sort -u "$TEST_TMP/session-actors")" "session runs as factory-autopilot"
  assert_eq factory-autopilot "$(sort -u "$TEST_TMP/actors")" "drain's bd calls run as factory-autopilot"
  assert_contains "$(cat "$STUBS/bd.calls")" "update bead-1 --status in_progress --assignee factory-autopilot --if-assignee '' --if-status open" "the drain claims the bead with a compare-and-set"
  assert_contains "$(cat "$STUBS/claude.calls")" 'Claimed\ for\ you\ by\ autopilot\ as\ factory-autopilot.' "prompt says claimed"
  cd - >/dev/null || return
}

test_failed_worker_doesnt_stop_others() {
  pool; beads 1
  echo bead-x >>"$TEST_TMP/beads" # no job: its session makes none
  factory/bin/autopilot --jobs 2 >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "exit 1 when a worker failed"
  assert_eq merged "$(jq -r .stage factory/jobs/001-j/job.json)" "the other job still merged"
  assert_eq "no" "$([ -e "$TEST_TMP/claims/bead-x" ] && echo yes || echo no)" "the jobless bead's claim is given back"
  cd - >/dev/null || return
}

test_watch_failure_keeps_worker() {
  pool; echo bead-x >>"$TEST_TMP/beads"; beads 1 # bead-x first: its session makes no job
  out=$(STUB_SLEEP=0 factory/bin/autopilot 2 --watch 2>&1); rc=$?
  assert_eq 1 "$rc" "the failure still sets the exit code"
  assert_contains "$out" "the session made no job" "the failure is logged"
  assert_eq merged "$(jq -r .stage factory/jobs/001-j/job.json)" "the same worker went on to the next bead"
  cd - >/dev/null || return
}

test_watch_failure_not_retried() {
  pool; echo bead-x >>"$TEST_TMP/beads"; beads 1
  STUB_SLEEP=0 factory/bin/autopilot --watch >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ "$(jq -r .stage factory/jobs/001-j/job.json)" != merged ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  sleep 1 # several empty polls, each forgetting the beads tried
  alive=$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq yes "$alive" "still watching after the failure"
  assert_eq 1 "$(grep -c 'adopt\\ bead-x' "$STUBS/claude.calls")" "a bead that made no job isn't tried again"
  cd - >/dev/null || return
}

test_skips_bead_held_by_same_actor() {
  pool; beads 2
  echo factory-autopilot >"$TEST_TMP/claims/bead-1" # another drain has it
  factory/bin/autopilot >/dev/null 2>&1
  assert_eq 1 "$(wc -l <"$STUBS/claude.calls" | tr -d ' ')" "one session"
  assert_contains "$(cat "$STUBS/claude.calls")" "adopt\ bead-2." "only the free bead ran"
  cd - >/dev/null || return
}

test_resubmitted_held_by_colleague_skipped() {
  pool
  mkjob 001-a bead-a resubmitted
  echo colleague >"$TEST_TMP/claims/bead-a"
  out=$(factory/bin/autopilot --jobs 2 2>&1); rc=$?
  assert_eq 0 "$rc" "exit 0"
  assert_eq "no" "$([ -e "$STUBS/claude.calls" ] && echo yes || echo no)" "no session as a colleague"
  assert_contains "$out" "[001-a] bead-a is assigned to colleague" "says why"
  assert_eq 1 "$(grep -c 'assigned to colleague' <<<"$out")" "said once"
  assert_eq "no" "$([ -e factory/jobs/001-a/.resume-claim ] && echo yes || echo no)" "resume claim given back"
  cd - >/dev/null || return
}

test_resubmitted_runs_as_own_actor() {
  pool
  me=$(git config user.name 2>/dev/null); me=${me:-$USER}
  mkjob 001-a bead-a resubmitted
  echo "$me" >"$TEST_TMP/claims/bead-a"
  mkjob 002-b bead-b resubmitted 2026-02-01T00:00:00Z
  echo factory-autopilot >"$TEST_TMP/claims/bead-b"
  factory/bin/autopilot >/dev/null 2>&1
  assert_eq "$me" "$(sed -n 1p "$TEST_TMP/session-actors")" "user's own bead resumes as the user"
  assert_eq factory-autopilot "$(sed -n 2p "$TEST_TMP/session-actors")" "drain's bead resumes as factory-autopilot"
  cd - >/dev/null || return
}

test_stop_hint_names_actor() {
  pool; beads 1
  STUB_SLEEP=2 factory/bin/autopilot >"$TEST_TMP/out" 2>&1 &
  pid=$!
  i=0
  while [ ! -e "$TEST_TMP/conc" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  kill -TERM "$pid" 2>/dev/null; wait "$pid"
  assert_contains "$(cat "$TEST_TMP/out")" "BEADS_ACTOR=factory-autopilot" "stop line says which actor to use"
  cd - >/dev/null || return
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
