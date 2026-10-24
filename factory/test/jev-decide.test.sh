#!/usr/bin/env bash
# Tests for factory/bin/jev-decide (route).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# setup [settings-json]: a repo, a job folder J with one in-progress task, a
# fake jev, and a fake Codex sessions dir.
setup() {
  local settings=${1:-'{"jev":{"send":"summary"}}'}
  R=$(mkrepo); J=$R/factory/jobs/j1
  mkdir -p "$J/build" "$R/src" "$TEST_TMP/sessions"
  rm -rf "$STUBS/fakejev.calls" "$TEST_TMP"/questions.sent "$TEST_TMP"/state.sent "$TEST_TMP"/jev.out "$TEST_TMP"/sessions/*
  printf '%s' "$settings" >"$R/factory/settings.json"
  printf 'a\nb\nc\n' >"$R/src/foo.sh"
  jq -n --arg wt "$R" '{round: 1, round_base: 0, worktree: $wt,
    tasks: [{id: "b.1", title: "Rename foo", status: "in_progress", runs: 1}]}' >"$J/job.json"
  jq -n '{status: "READY", tasks: [{key: "T1", title: "Rename foo",
    description: "Scope: rename in src/foo.sh. Contact me@example.com."}]}' >"$J/plan.json"
  # shellcheck disable=SC2016
  stub fakejev 'cp "$1" "$TEST_TMP/questions.sent"; cat "$2" >"$TEST_TMP/state.sent"; cat "$TEST_TMP/jev.out"; exit ${JEV_RC:-0}'
  export JEV_BIN=$STUBS/fakejev CODEX_SESSIONS_DIR=$TEST_TMP/sessions
  unset JEV_RC
}
# answer <choice> <p> [<state>]: what the fake jev prints.
answer() {
  jq -cn --arg c "$1" --argjson p "$2" --arg s "${3:-state}" \
    '{model: "jev-2", state: $s, answers: {route: {choice: $c, p: $p, probabilities: {($c): $p}}}, latency_ms: 80, input_tokens: 150}' \
    >"$TEST_TMP/jev.out"
}
route() { "$R/factory/bin/jev-decide" route "$J" "${1:-b.1}" 2>"$TEST_TMP/err"; }
logline() { tail -n 1 "$J/jev.jsonl"; }
# rollout <used-percent>: a Codex rollout whose last primary usage is that.
rollout() {
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}' \
    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":10.0}}}}" \
    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":$1}}}}" \
    >"$TEST_TMP/sessions/rollout-2026-10-24T10-00-00-abc.jsonl"
}

test_route_off() {
  setup '{}'; answer light 0.9
  assert_eq "builder (off)" "$(route)" "off output"
  if [ -e "$J/jev.jsonl" ] || [ -e "$STUBS/fakejev.calls" ]; then _fail "off logs or calls nothing"; else _pass; fi
  setup '{"jev":{"send":"summary","route":false}}'; answer light 0.9
  assert_eq "builder (off)" "$(route)" "route false output"
  if [ -e "$J/jev.jsonl" ]; then _fail "route false logs nothing"; else _pass; fi
}

test_route_light() {
  setup; answer light 0.9
  assert_eq "builder-light (jev light p=0.9)" "$(route)" "output"
  l=$(logline)
  assert_eq route "$(jq -r .decision <<<"$l")" "decision"
  assert_eq b.1 "$(jq -r .task <<<"$l")" "task"
  assert_eq summary "$(jq -r .send <<<"$l")" "send"
  assert_eq true "$(jq -r .outcome.route.used <<<"$l")" "used"
  assert_eq null "$(jq -c .outcome.route.why <<<"$l")" "why"
  assert_eq light "$(jq -r .answers.route.choice <<<"$l")" "logged answer"
  assert_eq 80 "$(jq -r .latency_ms <<<"$l")" "latency"
  s=$(cat "$TEST_TMP/state.sent")
  assert_contains "$s" "src/foo.sh" "state names the file"
  assert_contains "$s" "3 lines" "state has line count"
  assert_contains "$s" "Rename foo" "state has title in summary"
  assert_eq route "$(jq -r 'keys[0]' "$TEST_TMP/questions.sent")" "question key"
  assert_eq "a task that is merely long but straightforward" \
    "$(jq -r '.route.criteria.strong.not_for' "$TEST_TMP/questions.sent")" "strong not_for"
  assert_eq 4 "$(jq '.route.criteria | length' "$TEST_TMP/questions.sent")" "four options"
}

test_route_metadata_hides_description() {
  setup '{"jev":{"send":"metadata"}}'; answer light 0.9
  route >/dev/null
  s=$(cat "$TEST_TMP/state.sent")
  assert_contains "$s" "src/foo.sh" "path sent"
  case $s in *Scope:* | *"Rename foo"*) _fail "metadata leaks title or description" "$s" ;; *) _pass ;; esac
  assert_eq metadata "$(jq -r .send <<<"$(logline)")" "logged send"
}

test_route_missing_file_is_new() {
  setup; answer light 0.9
  jq '.tasks[0].description = "Scope: add src/new.sh."' "$J/plan.json" >"$J/p" && mv "$J/p" "$J/plan.json"
  route >/dev/null
  assert_contains "$(cat "$TEST_TMP/state.sent")" "src/new.sh (new)" "missing file is new"
}

test_route_labels() {
  setup; answer light 0.9
  jq '.tasks[0].final = true' "$J/job.json" >"$J/p" && mv "$J/p" "$J/job.json"
  route >/dev/null
  assert_contains "$(cat "$TEST_TMP/state.sent")" "final" "final label"
}

test_route_fix_files_from_review_and_triage() {
  setup; answer light 0.9
  jq '.tasks[0] = {id: "f.1", title: "Fix round 1 code review", status: "in_progress", runs: 1, fix: true}' "$J/job.json" >"$J/p" && mv "$J/p" "$J/job.json"
  mkdir -p "$J/round-1"
  printf 'VERDICT: CHANGES\n\n## Findings\n1. src/foo.sh:2 bad thing\n\n## Notes\nsee other/ignored.sh\n' >"$J/round-1/review-code.md"
  route "f.1" >/dev/null
  s=$(cat "$TEST_TMP/state.sent")
  assert_contains "$s" "src/foo.sh (3 lines)" "findings file"
  case $s in *ignored.sh*) _fail "notes are not findings" ;; *) _pass ;; esac
  assert_contains "$s" "fix" "fix label"
  jq '.tasks[0] = {id: "f.2", title: "Fix round 1 notes", status: "in_progress", runs: 1, fix: true}' "$J/job.json" >"$J/p" && mv "$J/p" "$J/job.json"
  printf '{"fix_now":[{"path":"src/foo.sh"}]}' >"$J/round-1/triage.json"
  route "f.2" >/dev/null
  assert_contains "$(cat "$TEST_TMP/state.sent")" "src/foo.sh (3 lines)" "triage file"
  rm "$J/round-1/triage.json"
  route "f.2" >/dev/null
  assert_eq 0 "$?" "missing triage.json is fine"
}

test_route_low_confidence() {
  setup; answer light 0.6
  assert_eq "builder (fallback low-confidence)" "$(route)" "output"
  l=$(logline)
  assert_eq false "$(jq -r .outcome.route.used <<<"$l")" "not used"
  assert_eq low-confidence "$(jq -r .outcome.route.why <<<"$l")" "why"
}

test_route_cap() {
  setup; answer strong 0.9; rollout 85.0
  assert_eq "builder (fallback cap)" "$(route)" "over the cap"
  assert_eq cap "$(jq -r .outcome.route.why <<<"$(logline)")" "why cap"
  rollout 50.0
  assert_eq "builder-escalation (jev strong p=0.9)" "$(route)" "under the cap"
  rm -rf "$TEST_TMP"/sessions/*
  assert_eq "builder-escalation (jev strong p=0.9)" "$(route)" "no rollout"
  rollout 85.0; touch -t 202001010000 "$TEST_TMP/sessions/rollout-2026-10-24T10-00-00-abc.jsonl"
  mkdir -p "$TEST_TMP/sessions/2026/10/24"
  { printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":20.0}}}}\n'; } \
    >"$TEST_TMP/sessions/2026/10/24/rollout-2026-10-24T11-00-00-new.jsonl"
  assert_eq "builder-escalation (jev strong p=0.9)" "$(route)" "newest rollout wins"
}

test_route_cap_only_for_strong() {
  setup; answer standard 0.9; rollout 99.0
  assert_eq "builder-standard (jev standard p=0.9)" "$(route)" "cap does not touch other tiers"
}

test_route_cap_skipped_for_claude() {
  setup; "$R/factory/bin/models" claude --force >/dev/null 2>&1
  answer strong 0.9; rollout 85.0
  assert_eq "builder-escalation (jev strong p=0.9)" "$(route)" "claude preset skips cap"
}

test_route_error() {
  setup; answer light 0.9
  stub fakejev 'echo "jev: HTTP 500" >&2; exit 1'
  assert_eq "builder (fallback error)" "$(route)" "output"
  assert_eq "jev: HTTP 500" "$(cat "$TEST_TMP/err")" "stderr once"
  l=$(logline)
  assert_eq error "$(jq -r .outcome.route.why <<<"$l")" "why error"
  assert_eq null "$(jq -c .state <<<"$l")" "no state when nothing was answered"
}

test_route_no_key() {
  setup; unset JEV_BIN JEV_KEY
  assert_eq "builder (fallback error)" "$(route)" "output"
  assert_exit 0 "exits 0" -- env -u JEV_KEY "$R/factory/bin/jev-decide" route "$J" b.1
}

test_route_missing_tier_key() {
  setup; answer light 0.9
  jq 'del(.["builder-light"])' "$R/factory/models.json" >"$R/m" && mv "$R/m" "$R/factory/models.json"
  assert_eq "builder (jev light p=0.9)" "$(route)" "maps to builder"
  l=$(logline)
  assert_eq true "$(jq -r .outcome.route.used <<<"$l")" "still used"
  assert_contains "$(jq -r .outcome.route.did <<<"$l")" "builder-light" "did mentions the missing key"
}

test_route_logs_redacted_state() {
  setup; answer light 0.9 'Task: [redacted] in src/foo.sh'
  route >/dev/null
  assert_eq 'Task: [redacted] in src/foo.sh' "$(jq -r .state <<<"$(logline)")" "state is jev's"
  case $(cat "$J/jev.jsonl") in *me@example.com*) _fail "email in log" ;; *) _pass ;; esac
}

test_route_history() {
  setup; answer light 0.9
  mkdir -p "$R/factory/jobs/j0/build"
  jq -n '{round: 1, tasks: [{id: "a.1", title: "Old", status: "closed", role: "builder", runs: 2}]}' >"$R/factory/jobs/j0/job.json"
  printf 'STATUS: DONE\n\n## Commit\nMessage: x\nFiles:\n- src/bar.sh\n\n## Changes\n- see docs/x.md edited\n- notes in other/dir\n' >"$R/factory/jobs/j0/build/a.1.md"
  route >/dev/null
  h=$(grep '^History:' "$TEST_TMP/state.sent")
  assert_eq "History: 1 earlier task touched src/. builder: 1 ran, 1 went BLOCKED." "$h" "history line"
}

test_route_history_ignores_prose_bullets() {
  setup; answer light 0.9
  mkdir -p "$R/factory/jobs/j0/build"
  jq -n '{round: 1, tasks: [{id: "a.1", title: "Old", status: "closed", role: "builder", runs: 2}]}' >"$R/factory/jobs/j0/job.json"
  printf 'STATUS: DONE\n\n## Commit\nMessage: x\nFiles:\n- lib/bar.sh\n\n## Changes\n- touched src/ in passing\n- src/foo.sh mentioned\n\n## Evidence\n- src/z\n' >"$R/factory/jobs/j0/build/a.1.md"
  route >/dev/null
  assert_eq "History: no earlier tasks touched src/." "$(grep '^History:' "$TEST_TMP/state.sent")" "prose bullets are not files"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
