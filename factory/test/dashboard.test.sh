#!/usr/bin/env bash
# Tests for factory/bin/dashboard.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A copy of the factory with fixture jobs; the server runs from it on a free port.
F="$TEST_TMP/f/factory"
mkdir -p "$TEST_TMP/f"
cp -R "$FACTORY_SRC" "$F"
rm -rf "$F/jobs" "$F/settings.json"
J="$F/jobs/001-a"
DETAIL="$F/jobs/005-e"
FILES_ONLY="$F/jobs/007-g"
NO_ROUNDS="$F/jobs/008-h"
TIE="$F/jobs/009-i"
mkdir -p "$J/round-1" "$J/.runs" "$F/jobs/002-b" "$F/jobs/003-c/.runs" "$F/jobs/004-d/.runs" \
  "$DETAIL/build" "$DETAIL/round-1" "$DETAIL/round-2" "$DETAIL/.runs" "$F/jobs/006-f/.runs" \
  "$FILES_ONLY" "$NO_ROUNDS/.runs" "$TIE/.runs"
echo '{"id":"001-a","feature":"A","stage":"review","round":2,"reviews":{}}' >"$J/job.json"
printf 'VERDICT: CHANGES\n' >"$J/round-1/review-code.md"
printf 'VERDICT: PASS\n' >"$J/round-1/review-security.md"
printf '# Spec\n' >"$J/spec.md"
echo '{"status":"READY","tasks":[]}' >"$J/plan.json"
printf '{"stage":"build","input":10,"output":2}\nnot json\n' >"$J/usage.jsonl"
printf 'prompt\n\nJob folder: x. Build task t.1.\n' >"$J/.runs/20261019-173747-builder.prompt.md"
printf '# Build output\n' >"$J/.runs/20261019-173747-builder.last.md"
printf '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":4}}\n{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":40,"output_tokens":5,"reasoning_output_tokens":2}}\n{truncated\n' >"$J/.runs/20261019-173747-builder.jsonl"
echo raw >"$J/.runs/20261019-173747-builder.stderr"
printf 'review\n\n… Review round 1.\n' >"$J/.runs/20261019-175425-reviewer-security.prompt.md"
printf '{"run":true}\n' >"$J/.runs/20261019-175427-reviewer-adversarial.json"
printf 'builder prompt\n' >"$J/.runs/20261019-180000-builder.prompt.md"
echo raw >"$J/.runs/log.md"
echo '{"id":"003-c","feature":"C","stage":"build"}' >"$F/jobs/003-c/job.json"
printf '{"type":"turn.completed","usage":{"input_tokens":7,"cached_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":1}}\n' >"$F/jobs/003-c/.runs/20261019-190000-builder.jsonl"
echo '{"id":"004-d","feature":"D","stage":"build"}' >"$F/jobs/004-d/job.json"
printf '{}\n' >"$F/jobs/004-d/.runs/20261020-100000-builder.json"
printf '{}\n' >"$F/jobs/004-d/.runs/20261020-110000-builder.json"
printf '{}\n' >"$F/jobs/004-d/.runs/20261020-120000-builder.json"
printf '{}\n' >"$F/jobs/004-d/.runs/20261020-130000-reviewer-code.json"
printf '{}\n' >"$F/jobs/004-d/.runs/20261020-090000-planner.json"
printf '{}\n' >"$F/jobs/004-d/.runs/20261020-100000-planner.json"
cat >"$F/jobs/004-d/usage.jsonl" <<'EOF'
{"ts":"2026-10-20T11:30:00","role":"builder","input":1,"cached":0,"output":1,"reasoning":0,"model":"claude-early","task":"early-task"}
{"ts":"2026-10-20T11:00:00","role":"builder","log":".runs/20261020-110000-builder","input":22,"cached":2,"output":3,"reasoning":1,"model":"codex-log"}
{"ts":"2026-10-20T12:30:00","role":"builder","input":4,"cached":1,"output":2,"reasoning":0,"model":"claude-latest"}
{"ts":"2026-10-20T08:00:00","role":"reviewer-code","input":5,"cached":0,"output":1,"reasoning":0,"model":"claude-before","task":"early-review","round":2}
{"ts":"2026-10-20T13:30:00","role":"reviewer-code","input":6,"cached":1,"output":2,"reasoning":1,"model":"claude-fallback","task":"fallback.task","round":9}
{"ts":"2026-10-20T10:30:00","role":"planner","input":7,"cached":2,"output":3,"reasoning":1,"model":"claude-planner-latest"}
EOF
echo '{"id":"005-e","feature":"Detail fixture","stage":"review","tasks":[{"id":"t.1","title":"First task","status":"closed"},{"id":"t.2","title":"Second task","status":"open"}]}' >"$DETAIL/job.json"
cat >"$DETAIL/spec.md" <<'EOF'
# Detail fixture

## aCcEpTaNcE cRiTeRiA   

1. First criterion
2. Second criterion
   - sub
3. Third criterion

## oUt Of ScOpE   

- Leave the unrelated service alone.

## Later

This section is not part of out of scope.
EOF
cat >"$DETAIL/plan.json" <<'EOF'
{"status":"READY","tasks":[{"key":"T1","title":"First task","covers":[1,2]},{"key":"T2","title":"Second task","covers":[3]}]}
EOF
printf '{"ts":"2026-10-20T09:00:30","role":"spec-writer","input":10,"cached":2,"output":4,"reasoning":1,"model":"claude-spec","log":"logs/spec-writer.jsonl"}\n{"ts":"2026-10-20T09:05:30","role":"planner","input":20,"cached":5,"output":6,"reasoning":2,"model":"claude-planner","log":"logs/planner.jsonl"}\n' >"$DETAIL/usage.jsonl"
for stem in 20261020-090000-spec-writer 20261020-090500-planner 20261020-093000-builder \
  20261020-094500-autopilot 20261020-100000-reviewer-adversarial 20261020-100000-reviewer-security \
  20261020-101500-approver 20261020-103000-autopilot \
  20261020-110000-reviewer-adversarial 20261020-110000-reviewer-security 20261020-111500-approver; do
  printf '{}\n' >"$DETAIL/.runs/$stem.json"
done
printf 'Build task t.1.\n' >"$DETAIL/.runs/20261020-093000-builder.prompt.md"
printf 'No round in this prompt.\n' >"$DETAIL/.runs/20261020-094500-autopilot.prompt.md"
printf 'Review round 1.\n' >"$DETAIL/.runs/20261020-100000-reviewer-security.prompt.md"
printf 'Final round: 1.\n' >"$DETAIL/.runs/20261020-101500-approver.prompt.md"
printf 'Decision file: autopilot-1.md.\n' >"$DETAIL/.runs/20261020-103000-autopilot.prompt.md"
printf 'Review round 2.\n' >"$DETAIL/.runs/20261020-110000-reviewer-security.prompt.md"
printf 'Final round: 2.\n' >"$DETAIL/.runs/20261020-111500-approver.prompt.md"
printf 'Build output.\n' >"$DETAIL/build/t.1.md"
printf 'Security review round 1.\n' >"$DETAIL/round-1/review-security.md"
printf 'Security review round 2.\n' >"$DETAIL/round-2/review-security.md"
printf 'Autopilot decision.\n' >"$DETAIL/autopilot-1.md"
printf 'Final approval.\n' >"$DETAIL/decision.md"
printf 'Round 1 approval.\n' >"$DETAIL/decision-round1.md"
printf 'Rework note.\n' >"$DETAIL/rework-1.md"
touch -t 202610201045 "$DETAIL/rework-1.md"
printf 'A note before round one.\n' >"$DETAIL/human-brief-before.md"
touch -t 202610200945 "$DETAIL/human-brief-before.md"
printf 'A note after the last round.\n' >"$DETAIL/human-brief-after.md"
touch -t 202610201130 "$DETAIL/human-brief-after.md"
echo '{"id":"006-f","feature":"No spec fixture","stage":"build"}' >"$F/jobs/006-f/job.json"
echo '{"id":"007-g","feature":"Files only","stage":"build"}' >"$FILES_ONLY/job.json"
printf '# Existing spec\n' >"$FILES_ONLY/spec.md"
echo '{"status":"READY","tasks":[]}' >"$FILES_ONLY/plan.json"
echo '{"id":"008-h","feature":"No review rounds","stage":"build"}' >"$NO_ROUNDS/job.json"
printf '{}\n' >"$NO_ROUNDS/.runs/20261020-120000-autopilot.json"
printf 'Decision file: autopilot-1.md.\n' >"$NO_ROUNDS/.runs/20261020-120000-autopilot.prompt.md"
printf 'An unanchored note.\n' >"$NO_ROUNDS/human-1.md"
echo '{"id":"009-i","feature":"Round inheritance tie","stage":"review"}' >"$TIE/job.json"
for stem in 20261020-100000-reviewer-security 20261020-103000-reviewer-adversarial 20261020-110000-reviewer-security; do
  printf '{}\n' >"$TIE/.runs/$stem.json"
done
printf 'Review round 1.\n' >"$TIE/.runs/20261020-100000-reviewer-security.prompt.md"
printf 'Review round 2.\n' >"$TIE/.runs/20261020-110000-reviewer-security.prompt.md"
echo '{"land":"local"}' >"$F/settings.json"
echo '{bad' >"$F/jobs/002-b/job.json"
printf '# Other\n' >"$F/jobs/002-b/spec.md"
ln -s "$F/models.json" "$J/link.md"

PORT=$(node -e 's=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
"$F/bin/dashboard" --port "$PORT" >"$TEST_TMP/srv.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TEST_TMP"' EXIT
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/api/state" >/dev/null && break; sleep 0.1; done

get() { curl -s "http://127.0.0.1:$PORT$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

test_page() {
  assert_contains "$(get /)" '<title>Software Factory</title>' "serves the page"
}

test_state() {
  local s; s=$(get /api/state)
  assert_eq local "$(jq -r .land <<<"$s")" "land from settings.json"
  assert_eq 8 "$(jq '.jobs | length' <<<"$s")" "skips the job with bad json and includes detail fixtures"
  assert_eq '["jobs/002-b/job.json is not valid JSON"]' "$(jq -c .problems <<<"$s")" "reports bad json"
  assert_eq 1 "$(jq '.jobs[0].usage | length' <<<"$s")" "skips usage lines that don't parse"
  assert_eq "CHANGES PASS missing" "$(jq -r '.jobs[0].past[0] | [.code, .security, .ux] | join(" ")' <<<"$s")" "past round verdicts"
  assert_eq builder "$(jq -r '.models.builder.agent // "builder"' <<<"$s")" "includes models.json"
}

test_files() {
  local f; f=$(get '/api/files?job=001-a')
  assert_eq "plan.json round-1/review-code.md round-1/review-security.md spec.md usage.jsonl" \
    "$(jq -r '[.[].path] | sort | join(" ")' <<<"$f")" "lists only servable files, no dot folders or links out"
  assert_eq "STATUS: READY" "$(jq -r '.[] | select(.path == "plan.json") | .first' <<<"$f")" "plan headline"
  assert_eq "# Spec" "$(get '/api/file?job=001-a&path=spec.md')" "serves a file"
}

test_refuses() {
  local u="http://127.0.0.1:$PORT"
  assert_eq 404 "$(code "$u/api/file?job=001-a&path=.runs/log.md")" "no dot folders"
  assert_eq 404 "$(code "$u/api/file?job=001-a&path=job.json")" "no job.json"
  assert_eq 404 "$(code "$u/api/file?job=001-a&path=../002-b/spec.md")" "no other job"
  assert_eq 404 "$(code "$u/api/file?job=001-a&path=link.md")" "no symlink out"
  assert_eq 404 "$(code "$u/api/files?job=..")" "no odd job ids"
  assert_eq 405 "$(code -X POST "$u/api/state")" "read-only"
}

test_runs() {
  local r; r=$(get '/api/runs?job=001-a')
  assert_eq 404 "$(code "http://127.0.0.1:$PORT/api/runs?job=missing")" "runs rejects a bad job id"
  assert_eq "20261019-173747-builder 20261019-175425-reviewer-security 20261019-175427-reviewer-adversarial 20261019-180000-builder" \
    "$(jq -r '[.[].id] | join(" ")' <<<"$r")" "runs in stamp order, died run included"
  assert_eq "t.1 build" "$(jq -r '.[0] | "\(.task) \(.stage)"' <<<"$r")" "task parsed from prompt"
  assert_eq "1 1" "$(jq -r '[.[1].round, .[2].round] | join(" ")' <<<"$r")" "review round parsed and inherited"
  assert_eq "150 derived" "$(jq -r '.[0] | "\(.tokens.input) \(.tokens_from)"' <<<"$r")" "tokens derived from turn.completed"
  assert_eq "null null" "$(jq -r '.[3] | "\(.tokens) \(.last)"' <<<"$r")" "died run has no tokens or output"
}

test_usage_attachment() {
  local r; r=$(get '/api/runs?job=004-d')
  assert_eq "claude-early usage 1" \
    "$(jq -r '.[] | select(.id == "20261020-100000-builder") | "\(.model) \(.tokens_from) \(.tokens.input)"' <<<"$r")" \
    "Claude record uses the remaining eligible builder stem"
  assert_eq "codex-log usage 22" \
    "$(jq -r '.[] | select(.id == "20261020-110000-builder") | "\(.model) \(.tokens_from) \(.tokens.input)"' <<<"$r")" \
    "run log record keeps its exact stem and usage tokens"
  assert_eq "claude-latest usage 4" \
    "$(jq -r '.[] | select(.id == "20261020-120000-builder") | "\(.model) \(.tokens_from) \(.tokens.input)"' <<<"$r")" \
    "Claude record attaches to latest same-key stem at or before its timestamp"
  assert_eq "claude-planner-latest usage" \
    "$(jq -r '.[] | select(.id == "20261020-100000-planner") | "\(.model) \(.tokens_from)"' <<<"$r")" \
    "Claude record chooses the latest of multiple eligible same-key stems"
  assert_eq "usage-3 reviewer-code claude-before" \
    "$(jq -r '.[] | select(.id == "usage-3") | "\(.id) \(.key) \(.model)"' <<<"$r")" \
    "Claude record before every same-key stem becomes its own run"
  assert_eq "fallback.task 9 claude-fallback usage" \
    "$(jq -r '.[] | select(.id == "20261020-130000-reviewer-code") | "\(.task) \(.round) \(.model) \(.tokens_from)"' <<<"$r")" \
    "task and round fall back to the attached record"
}

test_runs_served() {
  local u="http://127.0.0.1:$PORT/api/file?job=001-a&path=.runs/20261019-173747-builder"
  assert_eq 200 "$(code "$u.prompt.md")" "serves .prompt.md"
  assert_eq 200 "$(code "$u.last.md")" "serves .last.md"
  assert_eq 404 "$(code "$u.jsonl")" "refuses .jsonl"
  assert_eq 404 "$(code "$u.stderr")" "refuses .stderr"
  assert_eq 404 "$(code "http://127.0.0.1:$PORT/api/file?job=001-a&path=.runs/../job.json")" "no traversal through .runs"
}

test_detail() {
  local d; d=$(get '/api/detail?job=005-e')
  assert_eq 404 "$(code "http://127.0.0.1:$PORT/api/detail?job=missing")" "detail rejects a bad job id"
  assert_eq 3 "$(jq '.criteria | length' <<<"$d")" "three criteria"
  assert_contains "$(jq -r '.criteria[1].text' <<<"$d")" '- sub' "nested lines stay with their criterion"
  assert_eq "t.1" "$(jq -r '[.criteria[1].tasks[].id] | join(" ")' <<<"$d")" "covering tasks by plan order"
  assert_eq "t.1 t.2" "$(jq -r '[.plan.tasks[].id] | join(" ")' <<<"$d")" "plan tasks map to job task ids"
  assert_eq "closed" "$(jq -r '.criteria[0].tasks[0].status' <<<"$d")" "criterion task status comes from job.json"
  assert_eq "- Leave the unrelated service alone." "$(jq -r '.out_of_scope' <<<"$d")" "out of scope body stops at the next section"
  assert_eq "spec plan build between round between round approve" "$(jq -r '[.timeline[].kind] | join(" ")' <<<"$d")" "groups in story order"
  assert_eq "spec.md plan.json build/t.1.md" "$(jq -r '[.timeline[0].runs[0].output, .timeline[1].runs[0].output, .timeline[2].runs[0].output] | join(" ")' <<<"$d")" "spec, plan and build output paths"
  assert_eq "null" "$(jq -c '.timeline[2].runs[0].tokens' <<<"$d")" "run without token source stays unrecorded"
  assert_eq "autopilot-1.md rework-1.md" "$(jq -r '.timeline[5] | [.runs[0].output, .notes[0].path] | join(" ")' <<<"$d")" "between round 1 and 2"
  assert_eq "round-1/review-security.md decision-round1.md" "$(jq -r '[.timeline[4].runs[].output | select(. != null)] | join(" ")' <<<"$d")" "reviewer and round approval output paths"
  assert_eq "decision.md" "$(jq -r '.timeline[7].output' <<<"$d")" "final approver output"
  assert_eq "reviewer-adversarial:1 reviewer-security:1" \
    "$(jq -r '[.timeline[4].runs[] | select(.stage == "review") | "\(.key):\(.round)"] | join(" ")' <<<"$d")" \
    "same-stamp round-one adversarial run inherits round one"
  assert_eq "reviewer-adversarial:2 reviewer-security:2" \
    "$(jq -r '[.timeline[6].runs[] | "\(.key):\(.round)"] | join(" ")' <<<"$d")" \
    "same-stamp round-two adversarial run inherits round two"
  assert_eq "20261020-094500-autopilot human-brief-before.md" \
    "$(jq -r '.timeline[3] | [.runs[0].id, .notes[0].path] | join(" ")' <<<"$d")" \
    "pre-round run and unmatched note stay before round one"
  assert_eq "spec plan build between round between round approve" \
    "$(jq -r '[.timeline[].kind] | join(" ")' <<<"$d")" \
    "a trailing unmatched note joins a between group without adding one after the last round"
  assert_eq "rework-1.md human-brief-after.md" \
    "$(jq -r '[.timeline[5].notes[].path] | join(" ")' <<<"$d")" \
    "trailing note joins the nearest existing between group"
}

test_detail_no_spec() {
  rm -f "$F/jobs/006-f/spec.md"
  local d; d=$(get '/api/detail?job=006-f')
  assert_eq "null No spec yet." "$(jq -r '"\(.criteria) \(.criteria_note)"' <<<"$d")" "missing spec said plainly"
  assert_eq "[]" "$(jq -c .timeline <<<"$d")" "no runs, empty timeline"
}

test_detail_files_without_runs() {
  local d; d=$(get '/api/detail?job=007-g')
  assert_eq "spec plan" "$(jq -r '[.timeline[].kind] | join(" ")' <<<"$d")" "existing spec and plan appear without run records"
  assert_eq "spec.md plan.json" "$(jq -r '[.timeline[].output] | join(" ")' <<<"$d")" "file-only stage groups identify their output"
  assert_eq "0 0" "$(jq -r '[.timeline[].runs | length] | join(" ")' <<<"$d")" "file-only stage groups have empty run lists"
}

test_detail_unanchored_run_and_note() {
  local d; d=$(get '/api/detail?job=008-h')
  assert_eq "other" "$(jq -r '[.timeline[].kind] | join(" ")' <<<"$d")" "roundless run and note get an other group"
  assert_eq "20261020-120000-autopilot" "$(jq -r '.timeline[0].runs[0].id' <<<"$d")" "roundless autopilot is retained"
  assert_eq "human-1.md" "$(jq -r '.timeline[0].notes[0].path' <<<"$d")" "unmatched note is retained"
}

test_round_inheritance_tie() {
  local r; r=$(get '/api/runs?job=009-i')
  assert_eq 2 "$(jq -r '.[] | select(.key == "reviewer-adversarial") | .round' <<<"$r")" \
    "equidistant parsed review rounds resolve to the later round"
}

test_detail_no_criteria_section() {
  printf '# Spec without criteria\n\n## Out of scope\n\nNothing here.\n' >"$F/jobs/006-f/spec.md"
  local d; d=$(get '/api/detail?job=006-f')
  assert_eq "null The spec has no Acceptance criteria section." "$(jq -r '"\(.criteria) \(.criteria_note)"' <<<"$d")" "missing acceptance section said plainly"
}

test_derived_usage() {
  local s; s=$(get /api/state)
  assert_eq "true true" "$(jq -r '.jobs[] | select(.id == "003-c") | "\(.usage_derived) \(.usage[0].derived)"' <<<"$s")" "usage derived without usage.jsonl"
}

test_usage_and_port() {
  assert_exit 2 "bad args" -- "$F/bin/dashboard" --nope
  assert_exit 1 "port in use" -- "$F/bin/dashboard" --port "$PORT"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
