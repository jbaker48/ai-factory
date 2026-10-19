#!/usr/bin/env bash
# Tests for factory/bin/usage-record.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIX="$FACTORY_SRC/test/fixtures"
export CODEX_SESSIONS_DIR="$FIX/codex-sessions"
UR="$FACTORY_SRC/bin/usage-record"

# setup <fixture-name>: a job folder with a log copied from the fixture.
setup() {
  JOB="$TEST_TMP/job.$RANDOM"; mkdir -p "$JOB/.runs"
  PFX="$JOB/.runs/$(date +%Y%m%d-%H%M%S)-reviewer-security"
  [ -n "${1:-}" ] && cp "$FIX/$1.jsonl" "$PFX.jsonl"
  echo '{"stage":"review","round":2,"tasks":[{"id":"t1","status":"done"},{"id":"t2","status":"in_progress"}]}' >"$JOB/job.json"
}
run() { "$UR" codex "$JOB" "$PFX" "$@"; }
line() { wc -l <"$JOB/usage.jsonl" | tr -d ' '; }
field() { jq -c "$1" "$JOB/usage.jsonl"; }

test_single_turn() {
  setup codex-ok
  out=$(run reviewer-security 0 2>&1); rc=$?
  assert_eq "" "$out" "prints nothing"
  assert_eq 0 "$rc" "exit 0"
  assert_eq 1 "$(line)" "one line"
  assert_eq "[180312,155520,0,1272,24]" "$(field '[.input,.cached,.cache_write,.output,.reasoning]')" "tokens"
  assert_eq '["reviewer-security","openai","gpt-6-astra","medium","review",2,"t2",0,"turn.completed"]' \
    "$(field '[.role,.provider,.model,.effort,.stage,.round,.task,.exit,.ended]')" "metadata"
  assert_eq "\"${PFX#"$JOB"/}\"" "$(field .log)" "relative log"
  assert_eq true "$(field '(.duration_s|type=="number") and .duration_s >= 0')" "duration"
  assert_eq 18 "$(field '[keys[]]|length')" "exact keys"
}

test_huge_log() {
  setup codex-ok
  {
    head -n 3 "$FIX/codex-ok.jsonl"
    jq -n -c '{type:"item.completed",item:{text:("x" * 2000)}}' | awk '{for(i=0;i<400;i++)print}'
    tail -n 1 "$FIX/codex-ok.jsonl"
  } >"$PFX.jsonl"
  assert_eq true "$([ "$(wc -c <"$PFX.jsonl")" -gt 300000 ] && echo true)" "log is big"
  run reviewer-security 0
  assert_eq "[180312,155520,0,1272,24]" "$(field '[.input,.cached,.cache_write,.output,.reasoning]')" "tokens from big log"
  assert_eq null "$(field .error)" "no error"
}

test_task_only_when_unambiguous() {
  setup codex-ok
  echo '{"tasks":[{"id":"a","status":"in_progress"},{"id":"b","status":"in_progress"}]}' >"$JOB/job.json"
  run builder 0
  assert_eq null "$(field .task)" "two in progress"
  echo '{"tasks":[{"id":"a","status":"done"}]}' >"$JOB/job.json"
  run builder 0
  assert_eq null "$(tail -n 1 "$JOB/usage.jsonl" | jq -c .task)" "none in progress"
}

test_multi_turn_sums() {
  setup codex-multi-turn
  run builder 0
  assert_eq "[3000,2100,15,120,50]" "$(field '[.input,.cached,.cache_write,.output,.reasoning]')" "summed"
  assert_eq 'null' "$(field .quota)" "no rollout, null quota"
}

test_quota_from_rollout() {
  setup codex-ok
  run reviewer-security 0
  assert_eq true "$(field '.quota | .window=="weekly" and .before==30 and .after==32 and .resets_at==1792874508 and .plan=="prolite"')" "quota"
}

test_aborted_run() {
  setup codex-aborted
  run builder 1; rc=$?
  assert_eq 0 "$rc" "exit 0"
  assert_eq 1 "$(line)" "one line"
  assert_eq '[null,null,null,null,null]' "$(field '[.input,.cached,.cache_write,.output,.reasoning]')" "null tokens"
  assert_eq '["item.started",1]' "$(field '[.ended,.exit]')" "ended and exit"
}

test_no_log() {
  setup
  run builder 1
  assert_eq '[null,null]' "$(field '[.input,.ended]')" "missing log gives nulls"
}

test_thread_override_uses_rollout_tokens() {
  setup
  PFX="$JOB/.runs/20261019-175427-reviewer-adversarial"
  run reviewer-adversarial 0 --thread 01a152f0-a71f-7721-99c4-97eea420e361
  assert_eq "[180312,155520,0,1272,24]" "$(field '[.input,.cached,.cache_write,.output,.reasoning]')" "rollout tokens"
  assert_eq true "$(field '.quota.before==30 and .quota.after==32')" "quota"
  assert_eq '["codex-plugin","gpt-6.1-sol"]' "$(field '[.provider,.model]')" "provider"
}

test_window_names() {
  setup codex-ok
  d="$TEST_TMP/sess.$RANDOM"; mkdir -p "$d"
  for w in 300:5h 45:45m; do
    echo '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1,"window_minutes":'"${w%%:*}"',"resets_at":5},"plan_type":"p"}}}' \
      >"$d/rollout-x-01a152f0-a71f-7721-99c4-97eea420e361.jsonl"
    rm -f "$JOB/usage.jsonl"
    CODEX_SESSIONS_DIR=$d run builder 0
    assert_eq "\"${w#*:}\"" "$(field .quota.window)" "window ${w%%:*}"
  done
}

test_unwritable_never_fails() {
  setup codex-ok
  chmod a-w "$JOB"
  err=$("$UR" codex "$JOB" "$PFX" builder 0 2>&1 >/dev/null); rc=$?
  chmod u+w "$JOB"
  assert_eq 0 "$rc" "exit 0"
  assert_eq 1 "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "one stderr line"
  assert_contains "$err" "usage-record" "names itself"
}

test_unknown_role_error_line() {
  setup codex-ok
  run nonesuch 0
  assert_eq true "$(field '.error != null and .input == null')" "error line with nulls"
}

test_usage_and_unknown_subcommand() {
  assert_exit 0 "no args" -- "$UR"
  assert_exit 0 "unknown subcommand" -- "$UR" frob
}

test_run_codex_appends() {
  R=$(mkrepo); JOB="$R/job"; mkdir -p "$JOB"
  cp "$FIX/codex-ok.jsonl" "$TEST_TMP/codex.out"
  stub codex "cat '$TEST_TMP/codex.out'; exit 0"
  out=$("$R/factory/bin/run-codex" builder "$JOB" "$R" "do it"); rc=$?
  assert_eq 0 "$rc" "exit code kept"
  assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "still one line"
  assert_eq 1 "$(wc -l <"$JOB/usage.jsonl" | tr -d ' ')" "one usage line"
  assert_contains "$(cat "$JOB/usage.jsonl")" '"role":"builder"' "role"
}

test_run_adversarial_appends() {
  command -v node >/dev/null || return 0
  R=$(mkrepo); JOB="$R/job"; mkdir -p "$JOB"; echo spec >"$JOB/spec.md"
  echo 'console.log(JSON.stringify({threadId:"01a152f0-a71f-7721-99c4-97eea420e361",result:{verdict:"approve",summary:"s",findings:[],next_steps:[]}}))' >"$TEST_TMP/companion.js"
  out=$(CODEX_COMPANION="$TEST_TMP/companion.js" "$R/factory/bin/run-adversarial" "$JOB" "$R" 1); rc=$?
  assert_eq 0 "$rc" "exit code kept"
  assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "still one line"
  assert_eq '["reviewer-adversarial",180312]' "$(jq -c '[.role,.input]' "$JOB/usage.jsonl")" "recorded from rollout"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
