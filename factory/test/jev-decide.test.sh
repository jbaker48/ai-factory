#!/usr/bin/env bash
# Tests for factory/bin/jev-decide (route, triage).
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

# triage_fixture: round 1 reviews. Security has a Note, Code has none, and
# Adversarial has three Notes then next steps.
triage_fixture() {
  mkdir -p "$J/round-1"
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n\n## Notes\n- src/x.ts:4 token compare is not constant time.\n' >"$J/round-1/review-security.md"
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n\n## Notes\nNone.\n' >"$J/round-1/review-code.md"
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n\n## Notes\n%s\n%s\n%s\n\nSuggested next steps:\n- run tests\n\n## Evidence\n- src/zzz.ts\n' \
    '- src/api.ts:12 [medium, confidence 0.7] Off by one. The loop skips the last row. Fix: use <=.' \
    '- package.json:3 [low, confidence 0.5] Pin it. Version floats. Fix: pin.' \
    '- docs/a.md:1 [low, confidence 0.4] Typo. Says teh. Fix: the.' >"$J/round-1/review-adversarial.md"
}
# tanswer <note.k=choice:p>...: what the fake jev prints for triage.
tanswer() {
  jq -cn '{model: "jev-2", state: "st", answers: ([$ARGS.positional[] | capture("^(?<k>[^=]+)=(?<c>[^:]+):(?<p>.*)$")
      | {(.k): {choice: .c, p: (.p | tonumber), probabilities: {}}}] | add), latency_ms: 80, input_tokens: 150}' \
    --args "$@" >"$TEST_TMP/jev.out"
}
triage() { "$R/factory/bin/jev-decide" triage "$J" "${1:-1}" 2>"$TEST_TMP/err"; }
tj() { jq -c "$1" "$J/round-1/triage.json"; }

test_note_parsing() {
  setup; triage_fixture; tanswer note.1=fine:0.9 note.2=fine:0.9
  triage >/dev/null
  assert_eq 4 "$(tj '[.fix_now, .follow_up, .fine, .approver] | map(length) | add')" "four Notes"
  case $(cat "$J/round-1/triage.json") in *"run tests"* | *'"None.'*) _fail "next steps or None leaked" ;; *) _pass ;; esac
  assert_eq src/api.ts "$(tj '.fine[0].path' | tr -d '"')" "path without line"
  assert_eq "Off by one" "$(tj '.fine[0].title' | tr -d '"')" "adversarial title"
  assert_eq adversarial "$(tj '.fine[0].lens' | tr -d '"')" "lens"
  assert_eq 0.9 "$(tj '.fine[0].p')" "p"
}

test_park_root_files() {
  setup; triage_fixture
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n\n## Notes\n- package.json:3 [low, confidence 0.5] Pin it. x.\n- .env:1 [low, confidence 0.9] Leaks.\n- Dockerfile:2 [low, confidence 0.9] Old base.\n- docs/a.md:1 [low, confidence 0.4] Typo. x.\n' >"$J/round-1/review-adversarial.md"
  tanswer note.1=fine:0.9
  triage >/dev/null
  assert_eq 4 "$(tj '[.approver[] | select(.why == "guardrail")] | length')" "security, package.json, .env, Dockerfile"
  assert_eq 1 "$(tj '.fine | length')" "docs note settled"
  assert_eq '"package.json"' "$(tj '[.approver[] | select(.lens == "adversarial")][0].path')" "package.json parked"
}

test_guarded_not_sent() {
  setup; triage_fixture; tanswer note.1=fine:0.9 note.2=fine:0.9
  triage >/dev/null
  case $(cat "$TEST_TMP/state.sent") in *"Pin it"* | *"constant time"*) _fail "guarded Note in state" ;; *) _pass ;; esac
  assert_eq '["note.1","note.2"]' "$(jq -c 'keys' "$TEST_TMP/questions.sent")" "two questions"
  assert_contains "$(jq -r '.["note.2"].instructions.about' "$TEST_TMP/questions.sent")" "Note 2 in the state" "about"
  assert_contains "$(cat "$TEST_TMP/state.sent")" "Off by one" "summary state has text"
}

test_triage_outcomes() {
  setup; triage_fixture; tanswer note.1=fix-now:0.8 note.2=follow-up:0.75
  assert_eq "triage round 1: 1 fix-now, 1 follow-up, 0 fine, 2 for the approver" "$(triage)" "output"
  assert_eq "TRIAGE: 1 fix-now, 1 follow-up, 0 fine, 2 approver" "$(head -n 1 "$J/round-1/triage.md")" "md first line"
  assert_eq Typo "$(tj '.follow_up[0].title' | tr -d '"')" "title"
  md=$(cat "$J/round-1/triage.md")
  for h in '## Fix now' '## Follow-up' '## Fine' '## For the approver'; do assert_contains "$md" "$h" "$h"; done
  assert_contains "$md" "- [adversarial] src/api.ts:12 [medium, confidence 0.7] Off by one." "fix-now item"
  assert_contains "$md" "(p=0.8)" "p shown"
  assert_contains "$md" "— guardrail" "why shown"
  assert_contains "$md" "None." "empty section"
  l=$(logline)
  assert_eq triage "$(jq -r .decision <<<"$l")" "decision"
  assert_eq 1 "$(jq -r .round <<<"$l")" "round"
  assert_eq st "$(jq -r .state <<<"$l")" "state logged"
  assert_eq true "$(jq -r '.outcome["note.1"].used' <<<"$l")" "outcome used"
  assert_eq guardrail "$(jq -r '[.outcome[] | select(.why == "guardrail")][0].why' <<<"$l")" "guardrail outcome"
}

test_triage_earlier_round_path() {
  setup; triage_fixture; tanswer note.1=fine:0.9 note.2=fine:0.9
  jq '.round = 2' "$J/job.json" >"$J/p" && mv "$J/p" "$J/job.json"
  mkdir -p "$J/round-2"; cp "$J/round-1"/review-*.md "$J/round-2/"
  triage 2 >/dev/null
  assert_contains "$(cat "$TEST_TMP/state.sent")" "src/api.ts" "path in state"
  assert_contains "$(cat "$TEST_TMP/state.sent")" "raised before: yes" "earlier round noted"
  rm -rf "$J/round-1"; tanswer note.1=fine:0.9 note.2=fine:0.9; triage 2 >/dev/null
  assert_contains "$(cat "$TEST_TMP/state.sent")" "raised before: no" "none earlier"
}

test_triage_low_confidence() {
  setup; triage_fixture; tanswer note.1=fix-now:0.5 note.2=fine:0.9
  triage >/dev/null
  assert_eq 0 "$(tj '.fix_now | length')" "not fix-now"
  assert_eq low-confidence "$(tj '[.approver[] | select(.title == "Off by one")][0].why' | tr -d '"')" "why"
  assert_eq 1 "$(tj '.fine | length')" "other settled"
}

test_triage_metadata() {
  setup '{"jev":{"send":"metadata"}}'; triage_fixture; tanswer note.1=fine:0.9 note.2=approver:0.9
  assert_eq "triage round 1: 0 fix-now, 0 follow-up, 1 fine, 3 for the approver" "$(triage)" "output"
  assert_eq '["approver","fine"]' "$(jq -c '.["note.1"].criteria | keys' "$TEST_TMP/questions.sent")" "options"
  case $(cat "$TEST_TMP/state.sent") in *"Off by one"*) _fail "text leaked in metadata" ;; *) _pass ;; esac
  assert_contains "$(cat "$TEST_TMP/state.sent")" "medium" "severity sent"
  assert_eq jev "$(tj '[.approver[] | select(.title == "Typo")][0].why' | tr -d '"')" "jev chose approver"
  tanswer note.1=fix-now:0.9 note.2=fine:0.9
  triage >/dev/null
  assert_eq 0 "$(tj '.fix_now | length')" "fix-now not offered"
  assert_eq error "$(tj '[.approver[] | select(.title == "Off by one")][0].why' | tr -d '"')" "unoffered choice is an error"
}

test_triage_park_extend() {
  setup '{"jev":{"send":"summary","park_paths":["docs/**"]}}'; triage_fixture; tanswer note.1=fine:0.9
  triage >/dev/null
  assert_eq guardrail "$(tj '[.approver[] | select(.title == "Typo")][0].why' | tr -d '"')" "docs parked"
  assert_eq '["note.1"]' "$(jq -c keys "$TEST_TMP/questions.sent")" "one question"
}

test_triage_error() {
  setup; triage_fixture; tanswer note.1=fine:0.9 note.2=fine:0.9; export JEV_RC=1
  triage >/dev/null
  assert_eq 4 "$(tj '.approver | length')" "all to approver"
  assert_eq 2 "$(tj '[.approver[] | select(.why == "error")] | length')" "two errors"
  if [ -f "$J/round-1/triage.md" ]; then _pass; else _fail "triage.md written"; fi
  assert_eq error "$(jq -r '.outcome["note.1"].why' <<<"$(logline)")" "logged error"
  unset JEV_RC
}

test_triage_all_guarded() {
  setup; triage_fixture
  printf 'VERDICT: PASS\n\n## Notes\n- package.json:1 [low, confidence 0.9] x.\n' >"$J/round-1/review-adversarial.md"
  rm -rf "$STUBS/fakejev.calls"
  assert_eq "triage round 1: 0 fix-now, 0 follow-up, 0 fine, 2 for the approver" "$(triage)" "output"
  if [ -e "$STUBS/fakejev.calls" ]; then _fail "jev called"; else _pass; fi
  assert_eq null "$(jq -c .state <<<"$(logline)")" "state null"
}

test_triage_off() {
  setup '{}'; triage_fixture
  assert_eq "triage round 1: off" "$(triage)" "off"
  if [ -e "$J/round-1/triage.json" ]; then _fail "wrote triage.json"; else _pass; fi
  setup '{"jev":{"send":"summary","triage":false}}'; triage_fixture
  assert_eq "triage round 1: off" "$(triage)" "triage false"
  if [ -e "$J/round-1/triage.json" ]; then _fail "wrote triage.json"; else _pass; fi
}

# guard_note <note-line>: round 1 whose only adversarial Note is that line.
guard_note() {
  triage_fixture
  rm "$J/round-1/review-security.md"
  printf 'VERDICT: PASS\n\n## Notes\n- %s\n' "$1" >"$J/round-1/review-adversarial.md"
  tanswer note.1=fine:0.9
  triage >/dev/null
}

test_guard_nested_and_forms() {
  setup
  local note
  # shellcheck disable=SC2016 # backticks are literal Note text
  for note in 'src/auth/login.ts:4 [low, confidence 0.9] X. y.' \
    '.github/workflows/ci.yml:2 [low, confidence 0.9] X. y.' \
    'infra/main.tf:2 [low, confidence 0.9] X. y.' \
    'yarn.lock:1 [low, confidence 0.9] X. y.' \
    'src/app/secrets.ts:1 [low, confidence 0.9] X. y.' \
    '**package.json**:3 pin it' \
    'package.json:3-5 pin it' \
    'src/x/package.json#L4 pin it' \
    'src/x/package.json#L4-L9 pin it' \
    '`package.json:3:7` pin it' \
    '_package.json_ pin it' \
    'and/or the .env file leaks' \
    'e.g. the .env leak' \
    'src/app/Secrets.ts:1 odd' \
    'See .ENV for it'; do
    setup; guard_note "$note"
    assert_eq 1 "$(tj '[.approver[] | select(.why == "guardrail")] | length')" "guarded: $note"
    if [ -e "$STUBS/fakejev.calls" ]; then _fail "sent: $note"; else _pass; fi
  done
  setup; guard_note 'src/app/page.ts:1 [low, confidence 0.9] X. y.'
  assert_eq 1 "$(tj '.fine | length')" "ordinary path is sent"
  setup; guard_note 'and/or the .env file leaks'
  assert_eq '"and/or"' "$(tj '.approver[0].path')" "reported path stays the first token"
  setup; guard_note '**package.json**:3 pin it'
  assert_eq '"package.json"' "$(tj '.approver[0].path')" "wrappers stripped from path"
}

# rsetup: setup plus a job branch with one commit changing docs/a.md.
rsetup() {
  setup "$@"
  mkdir -p "$R/docs"
  echo a >"$R/docs/a.md"
  git -C "$R" checkout -q -b job/j1 && git -C "$R" add docs && git -C "$R" commit -q -m "change docs"
}
# ranswer <lens>=<choice>:<p> ...: what the fake jev prints for the review questions.
ranswer() {
  local a lens rest args='{}'
  for a in "$@"; do
    lens=${a%%=*} rest=${a#*=}
    args=$(jq -c --arg k "review.$lens" --arg c "${rest%%:*}" --argjson p "${rest#*:}" \
      '. + {($k): {choice: $c, p: $p, probabilities: {($c): $p}}}' <<<"$args")
  done
  jq -cn --argjson a "$args" '{model: "jev-2", state: "state", answers: $a, latency_ms: 80, input_tokens: 150}' >"$TEST_TMP/jev.out"
}
reviewers() { "$R/factory/bin/jev-decide" reviewers "$J" "${1:-1}" 2>"$TEST_TMP/err"; }
sent_keys() { jq -r 'keys | join(",")' "$TEST_TMP/questions.sent"; }

test_reviewers_first_round() {
  rsetup; ranswer ux=skip:0.9 ui=skip:0.9
  assert_eq "reviewers round 1: run security, code, adversarial; skip ux (p=0.9), ui (p=0.9)" "$(reviewers 1)" "output"
  assert_eq "review.ui,review.ux" "$(sent_keys)" "questions sent"
  assert_eq "skip" "$(jq -r '.["review.ux"].criteria | keys | map(select(. == "skip")) | .[0]' "$TEST_TMP/questions.sent")" "skip offered"
  assert_eq "a change that might alter what this reviewer checks" \
    "$(jq -r '.["review.ux"].criteria.skip.not_for' "$TEST_TMP/questions.sent")" "skip not_for"
  f=$J/round-1/review-ux.md
  assert_eq "VERDICT: SKIPPED" "$(sed -n 1p "$f")" "line 1"
  assert_eq "" "$(sed -n 2p "$f")" "line 2 blank"
  l3=$(sed -n 3p "$f")
  case $l3 in "Skipped by Jev (p=0.9): ux: "*.) _pass ;; *) _fail "line 3" "$l3" ;; esac
  assert_eq 3 "$(wc -l <"$f" | tr -d ' ')" "three lines"
  l=$(logline)
  assert_eq reviewers "$(jq -r .decision <<<"$l")" "decision"
  assert_eq skip "$(jq -r '.outcome["review.ux"].did' <<<"$l")" "did skip"
  assert_eq true "$(jq -r '.outcome["review.ux"].used' <<<"$l")" "used"
}

test_reviewers_round_two_asks_all() {
  rsetup; mkdir -p "$J/round-1"
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n\n## Notes\n- one thing\n' >"$J/round-1/review-security.md"
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n\n## Notes\nNone.\n' >"$J/round-1/review-code.md"
  ranswer ux=run:0.9 ui=run:0.9 security=run:0.9 code=run:0.9
  assert_eq "reviewers round 2: run all" "$(reviewers 2)" "output"
  assert_eq "review.code,review.security,review.ui,review.ux" "$(sent_keys)" "questions sent"
  s=$(cat "$TEST_TMP/state.sent")
  assert_contains "$s" "security: previous round PASS" "security line"
  assert_eq run "$(jq -r '.outcome["review.code"].did' <<<"$(logline)")" "did run"
}

test_reviewers_round_two_fix_files() {
  rsetup; mkdir -p "$J/round-1"
  printf 'VERDICT: CHANGES\n\n## Findings\n1. bad\n2. worse\n\n## Notes\nNone.\n' >"$J/round-1/review-code.md"
  jq '.tasks += [{id: "f.1", title: "Fix round 1 review", status: "done", runs: 1}]' "$J/job.json" >"$J/j.tmp" && mv "$J/j.tmp" "$J/job.json"
  printf '## Commit\nFiles:\n- src/fixed.sh\n' >"$J/build/f.1.md"
  ranswer ux=run:0.9 ui=run:0.9 security=run:0.9 code=run:0.9
  reviewers 2 >/dev/null
  s=$(cat "$TEST_TMP/state.sent")
  assert_contains "$s" "code: previous round CHANGES, 2 findings, 0 notes" "code counts"
  assert_contains "$s" "src/fixed.sh" "fix task files"
}

test_reviewers_low_confidence_runs() {
  rsetup; ranswer ux=skip:0.6 ui=skip:0.6
  assert_eq "reviewers round 1: run all" "$(reviewers 1)" "output"
  if [ -e "$J/round-1/review-ux.md" ]; then _fail "no file written"; else _pass; fi
  assert_eq low-confidence "$(jq -r '.outcome["review.ux"].why' <<<"$(logline)")" "why"
  assert_eq run "$(jq -r '.outcome["review.ux"].did' <<<"$(logline)")" "did run"
}

test_reviewers_ui_file_line() {
  rsetup
  mkdir -p "$R/src/components"; echo x >"$R/src/components/Button.tsx"
  git -C "$R" add src && git -C "$R" commit -q -m ui
  ranswer ux=run:0.9 ui=run:0.9
  reviewers 1 >/dev/null
  assert_contains "$(cat "$TEST_TMP/state.sent")" "ui: 1 UI file (src/components/Button.tsx)" "ui line"
}

test_reviewers_existing_file_kept() {
  rsetup; mkdir -p "$J/round-1"; echo keep >"$J/round-1/review-ux.md"
  ranswer ui=run:0.9
  reviewers 1 >/dev/null
  assert_eq keep "$(cat "$J/round-1/review-ux.md")" "not rewritten"
  assert_eq "review.ui" "$(sent_keys)" "ux not asked"
}

test_reviewers_error_runs_all() {
  rsetup; ranswer ux=skip:0.9 ui=skip:0.9
  export JEV_RC=1
  assert_eq "reviewers round 1: run all" "$(reviewers 1)" "output"
  unset JEV_RC
  assert_eq error "$(jq -r '.outcome["review.ux"].why' <<<"$(logline)")" "why error"
  if [ -e "$J/round-1/review-ux.md" ]; then _fail "no file written"; else _pass; fi
}

test_reviewers_bad_choice_runs() {
  rsetup; ranswer ux=maybe:0.9 ui=skip:0.9
  assert_eq "reviewers round 1: run ux, security, code, adversarial; skip ui (p=0.9)" "$(reviewers 1)" "output"
}

test_reviewers_off() {
  rsetup '{}'; ranswer ux=skip:0.9 ui=skip:0.9
  assert_eq "reviewers round 1: run all" "$(reviewers 1)" "off output"
  rsetup '{"jev":{"send":"summary","reviewers":false}}'; ranswer ux=skip:0.9 ui=skip:0.9
  assert_eq "reviewers round 1: run all" "$(reviewers 1)" "reviewers false output"
  if [ -e "$J/jev.jsonl" ] || [ -e "$STUBS/fakejev.calls" ]; then _fail "nothing logged or called"; else _pass; fi
}

test_reviewers_many_files() {
  rsetup
  mkdir -p "$R/gen"; for i in $(seq 1 59); do echo x >"$R/gen/f$i.txt"; done
  git -C "$R" add gen && git -C "$R" commit -q -m many
  ranswer ux=run:0.9 ui=run:0.9
  reviewers 1 >/dev/null
  s=$(cat "$TEST_TMP/state.sent")
  assert_contains "$s" "and 20 more" "more"
  assert_eq 40 "$(grep -c '^- ' "$TEST_TMP/state.sent")" "40 listed"
}

test_reviewers_git_failure_runs_all() {
  local case_
  for case_ in missing empty badbase; do
    rsetup; ranswer ux=skip:0.9 ui=skip:0.9
    case $case_ in
      missing) jq '.worktree = "/nonexistent/wt"' "$J/job.json" >"$J/j.tmp" && mv "$J/j.tmp" "$J/job.json" ;;
      empty) jq 'del(.worktree)' "$J/job.json" >"$J/j.tmp" && mv "$J/j.tmp" "$J/job.json" ;;
      badbase) git -C "$R" remote remove origin ;;
    esac
    assert_eq "reviewers round 1: run all" "$(reviewers 1)" "$case_ output"
    if ls "$J"/round-1/review-*.md >/dev/null 2>&1; then _fail "$case_ wrote a review file"; else _pass; fi
    if [ -e "$STUBS/fakejev.calls" ]; then _fail "$case_ called jev"; else _pass; fi
  done
}

test_reviewers_later_run_first_round() {
  rsetup; jq '.round_base = 2' "$J/job.json" >"$J/j.tmp" && mv "$J/j.tmp" "$J/job.json"
  mkdir -p "$J/round-2"
  ranswer ux=run:0.9 ui=run:0.9
  assert_eq "reviewers round 3: run all" "$(reviewers 3)" "output"
  assert_eq "review.ui,review.ux" "$(sent_keys)" "only ux and ui asked"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
