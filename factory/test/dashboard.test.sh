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
mkdir -p "$J/round-1" "$J/.runs" "$F/jobs/002-b"
echo '{"id":"001-a","feature":"A","stage":"review","round":2,"reviews":{}}' >"$J/job.json"
printf 'VERDICT: CHANGES\n' >"$J/round-1/review-code.md"
printf 'VERDICT: PASS\n' >"$J/round-1/review-security.md"
printf '# Spec\n' >"$J/spec.md"
echo '{"status":"READY","tasks":[]}' >"$J/plan.json"
printf '{"stage":"build","input":10,"output":2}\nnot json\n' >"$J/usage.jsonl"
echo raw >"$J/.runs/log.md"
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
  assert_eq 1 "$(jq '.jobs | length' <<<"$s")" "skips the job with bad json"
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

test_usage_and_port() {
  assert_exit 2 "bad args" -- "$F/bin/dashboard" --nope
  assert_exit 1 "port in use" -- "$F/bin/dashboard" --port "$PORT"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
