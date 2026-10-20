#!/usr/bin/env bash
# Tests for factory/bin/dashboard.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A copy of the factory with two jobs; the server runs from it on a free port.
F="$TEST_TMP/f/factory"
mkdir -p "$TEST_TMP/f"
cp -R "$FACTORY_SRC" "$F"
rm -rf "$F/jobs" "$F/settings.json"
J="$F/jobs/001-a"
mkdir -p "$J/round-1" "$J/.runs" "$F/jobs/002-b" "$F/jobs/003-c/.runs" "$F/jobs/004-d/.runs"
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
  assert_eq 3 "$(jq '.jobs | length' <<<"$s")" "skips the job with bad json"
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
