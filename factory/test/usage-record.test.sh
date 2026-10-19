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

# Claude sources. The fixture project is copied under a temp projects dir at
# the slug of this repo (where the script looks), and the job folder ends in
# factory/jobs/001-demo like the fixture prompts.
CSID=5e55a0f1-0000-4000-8000-000000000001
setup_claude() {
  export CLAUDE_PROJECTS_DIR="$TEST_TMP/projects.$RANDOM"
  PROJ="$CLAUDE_PROJECTS_DIR/$(cd "$FACTORY_SRC/.." && pwd | sed 's#[/.]#-#g')"
  mkdir -p "$PROJ" && cp -R "$FIX/claude-project/." "$PROJ/"
  JOB="$TEST_TMP/w.$RANDOM/factory/jobs/${1:-001-demo}"; mkdir -p "$JOB"
  echo '{"stage":"spec","round":0,"tasks":[]}' >"$JOB/job.json"
}

test_subagent_tokens_dedup() {
  setup_claude
  out=$("$UR" claude "$JOB" spec-writer 2>&1); rc=$?
  assert_eq "" "$out" "prints nothing"
  assert_eq 0 "$rc" "exit 0"
  assert_eq 1 "$(line)" "one line"
  assert_eq "[46720,29421,17294,484,null]" "$(field '[.input,.cached,.cache_write,.output,.reasoning]')" "each message id once, last usage wins"
  assert_eq '["spec-writer","anthropic","claude-opus-5-5",null,"spec",0,null,null,"finished",null,167]' \
    "$(field '[.role,.provider,.model,.effort,.stage,.round,.task,.exit,.ended,.quota,.duration_s]')" "metadata"
  assert_eq "\"$PROJ/$CSID/subagents/agent-a1.jsonl\"" "$(field .log)" "log is the transcript"
  assert_eq 18 "$(field '[keys[]]|length')" "exact keys"
}

test_subagent_not_recorded_twice() {
  setup_claude
  "$UR" claude "$JOB" spec-writer
  "$UR" claude "$JOB" spec-writer
  assert_eq 1 "$(line)" "one line after two runs"
}

test_matches_role_and_job() {
  setup_claude
  "$UR" claude "$JOB" reviewer-code
  assert_eq 1 "$(line)" "only the reviewer-code transcript"
  assert_eq '["reviewer-code",1203,40,null,"claude-opus-5-5",30]' "$(field '[.role,.input,.output,.ended,.model,.duration_s]')" "content-array prompt, no meta"
  setup_claude 003-none
  "$UR" claude "$JOB" spec-writer
  assert_eq 1 "$(line)" "no transcript for this job: one error line"
  assert_eq true "$(field '.error != null and .input == null')" "error with null tokens"
  setup_claude 002-other
  "$UR" claude "$JOB" spec-writer
  assert_eq 102 "$(field .input)" "other job's transcript only"
}

test_subagent_model_from_meta() {
  setup_claude
  sed -i.bak 's/"model":"claude-opus-5-5",//' "$PROJ/$CSID/subagents/agent-a1.jsonl"
  "$UR" claude "$JOB" spec-writer
  assert_eq '"opus"' "$(field .model)" "meta model when transcript has none"
}

test_session_main_transcript_only() {
  setup_claude
  out=$("$UR" session "$JOB" "$CSID" 2>&1); rc=$?
  assert_eq "" "$out" "prints nothing"
  assert_eq 0 "$rc" "exit 0"
  assert_eq "[6204,5000,1200,90,null]" "$(field '[.input,.cached,.cache_write,.output,.reasoning]')" "main transcript tokens only"
  assert_eq '["orchestrator","anthropic","claude-opus-5-5",null,null,null,600]' \
    "$(field '[.role,.provider,.model,.effort,.ended,.exit,.duration_s]')" "metadata"
  assert_eq "\"$PROJ/$CSID.jsonl\"" "$(field .log)" "log"
  assert_eq 18 "$(field '[keys[]]|length')" "exact keys"
}

test_session_once_per_id() {
  setup_claude
  "$UR" session "$JOB" "$CSID"
  "$UR" session "$JOB" "$CSID"
  assert_eq 1 "$(line)" "one line per session"
}

test_session_latest_mentioning_job() {
  setup_claude
  touch -t 202610190100 "$PROJ/$CSID.jsonl"
  touch -t 202610190200 "$PROJ/5e55a0f1-0000-4000-8000-000000000002.jsonl"
  touch -t 202610190300 "$PROJ/5e55a0f1-0000-4000-8000-000000000003.jsonl"
  "$UR" session "$JOB"
  assert_eq 7 "$(field .input)" "newest transcript that mentions the job"
}

test_claude_failures_never_fail() {
  setup_claude
  out=$("$UR" session "$JOB" no-such-session 2>&1); rc=$?
  assert_eq "" "$out" "prints nothing"
  assert_eq 0 "$rc" "exit 0"
  assert_eq true "$(field '.error != null and .input == null and .role == "orchestrator"')" "error line"
  assert_exit 0 "claude without role" -- "$UR" claude "$JOB"
  CLAUDE_PROJECTS_DIR="$TEST_TMP/nowhere" "$UR" claude "$JOB" spec-writer; rc=$?
  assert_eq 0 "$rc" "no projects dir"
}

test_autopilot_records_sessions() {
  R=$(mkrepo); cd "$R" || return
  mkdir -p factory/jobs/001-demo
  echo '{"id":"001-demo","bead":"demo-1","stage":"merged"}' >factory/jobs/001-demo/job.json
  stub claude 'echo "{\"session_id\":\"sid-1\",\"total_cost_usd\":0}"'
  # shellcheck disable=SC2016 # the stub expands these when it runs
  printf '#!/usr/bin/env bash\nn=$(cat "%s/n" 2>/dev/null || echo 0); echo $((n+1)) >"%s/n"; [ "$n" = 0 ] && echo demo-1; exit 0\n' "$TEST_TMP" "$TEST_TMP" >factory/bin/next-bead
  printf '#!/usr/bin/env bash\necho "$@" >>"%s/ur.calls"\n' "$TEST_TMP" >factory/bin/usage-record
  factory/bin/autopilot 1 >/dev/null 2>&1
  assert_eq "session factory/jobs/001-demo sid-1" "$(cat "$TEST_TMP/ur.calls" 2>/dev/null)" "records the session"
  cd - >/dev/null || return
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
