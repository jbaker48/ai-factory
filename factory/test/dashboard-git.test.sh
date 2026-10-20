#!/usr/bin/env bash
# Tests for task commits and read-only Git diffs in the dashboard.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO=$(mkrepo)
F="$REPO/factory"
J="$F/jobs/001-a"
J2="$F/jobs/002-b"
mkdir -p "$J" "$J2"
cat >"$J/job.json" <<'EOF'
{"id":"001-a","stage":"review","bead":"b-1","tasks":[{"id":"b-1.1"},{"id":"b-1.10"},{"id":"b-1.2"}]}
EOF
echo '{"land":"local"}' >"$F/settings.json"

printf 'before rename\n' >"$REPO/rename-old.txt"
git -C "$REPO" add rename-old.txt
git -C "$REPO" commit -q -m 'prepare rename fixture'
git -C "$REPO" switch -q -c factory/001-a
printf 'one\ntwo\nthree\n' >"$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m 'add a (b-1.10)'
printf 'one\ntwo\nthree\n' >"$REPO/b.txt"
git -C "$REPO" add b.txt
git -C "$REPO" commit -q -m 'add b (b-1.1)'
printf 'four\nfive\n' >"$REPO/c.txt"
git -C "$REPO" add c.txt
git -C "$REPO" commit -q -m 'add c (b-1.10)'
git -C "$REPO" mv rename-old.txt renamed-new.txt
printf 'new file\n' >"$REPO/café.txt"
git -C "$REPO" add café.txt
git -C "$REPO" commit -q -m 'rename and add unicode file (b-1.2)'

PORT=$(node -e 's=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
SRV=
stop_server() {
  if [ -n "$SRV" ]; then kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=; fi
}
start_server() {
  local root=$1 cap=${2:-}
  if [ -n "$cap" ]; then
    FACTORY_DASHBOARD_DIFF_CAP="$cap" "$root/bin/dashboard" --port "$PORT" >"$TEST_TMP/srv.log" 2>&1 &
  else
    "$root/bin/dashboard" --port "$PORT" >"$TEST_TMP/srv.log" 2>&1 &
  fi
  SRV=$!
  for _ in $(seq 50); do
    if curl -s "http://127.0.0.1:$PORT/api/state" >/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
trap 'stop_server; rm -rf "$TEST_TMP"' EXIT
start_server "$F"

get() { curl -s "http://127.0.0.1:$PORT$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

test_task_commits() {
  local c hash; c=$(get '/api/changes?job=001-a')
  assert_eq branch "$(jq -r .source <<<"$c")" "finds the job branch"
  assert_eq "b.txt 3" "$(jq -r '.tasks["b-1.1"].files[0] | "\(.path) \(.added)"' <<<"$c")" "b-1.1 is not matched by (b-1.10)"
  assert_eq "c.txt" "$(jq -r '.tasks["b-1.10"].files[0].path' <<<"$c")" "b-1.10 resolves to its newest commit"
  assert_eq "branch 5" "$(jq -r '.job | "\(.kind) \(.files | length)"' <<<"$c")" "whole job against main"
  assert_contains "$(get '/api/diff?job=001-a&task=b-1.1')" '+++ b/b.txt' "task diff"
  hash=$(jq -r '.tasks["b-1.1"].commit' <<<"$c")
  assert_contains "$(get "/api/diff?job=001-a&commit=$hash")" '+++ b/b.txt' "diff accepts this job's task commit"
}

test_renamed_and_non_ascii_paths_match_page_diff() {
  local changes diff parsed paths
  changes=$(get '/api/changes?job=001-a')
  diff=$(get '/api/diff?job=001-a&task=b-1.2')
  paths=$(jq -c '[.tasks["b-1.2"].files[].path] | sort' <<<"$changes")
  assert_eq '["café.txt","renamed-new.txt"]' "$paths" "/api/changes keeps destination paths and Unicode"
  parsed=$(printf '%s' "$diff" | node -e '
const fs = require("fs")
const vm = require("vm")
const html = fs.readFileSync(process.argv[1], "utf8")
const view = html.match(/<script id="view">([\s\S]*?)<\/script>/)[1]
const context = vm.createContext({})
vm.runInContext(view, context)
context.diffText = fs.readFileSync(0, "utf8")
process.stdout.write(JSON.stringify(vm.runInContext("parseDiff(diffText).map((file) => file.path)", context)))
' "$FACTORY_SRC/dashboard.html")
  assert_eq "$paths" "$(jq -c 'sort' <<<"$parsed")" "/api/changes paths match parseDiff of /api/diff"
}

test_git_diff_disables_textconv() {
  local marker="$TEST_TMP/textconv-ran"
  cat >"$TEST_TMP/textconv" <<EOF
#!/usr/bin/env bash
touch "$marker"
cat "\$1"
EOF
  chmod +x "$TEST_TMP/textconv"
  printf '*.txt diff=dashboard-test\n' >"$TEST_TMP/attributes"
  git -C "$REPO" config diff.dashboard-test.textconv "$TEST_TMP/textconv"
  git -C "$REPO" config core.attributesFile "$TEST_TMP/attributes"
  get '/api/changes?job=001-a' >/dev/null
  get '/api/diff?job=001-a&task=b-1.1' >/dev/null
  assert_eq false "$([ -e "$marker" ] && echo true || echo false)" "stats and diffs never run configured textconv"
}

test_host_check() {
  local url="http://127.0.0.1:$PORT/api/state" body
  assert_eq 200 "$(code "$url")" "normal loopback Host is accepted"
  assert_eq 200 "$(code -H "Host: localhost:$PORT" "$url")" "localhost Host is accepted"
  assert_eq 403 "$(code -H "Host: evil.example:$PORT" "$url")" "untrusted Host is refused"
  body=$(curl -s -H "Host: evil.example:$PORT" "$url")
  assert_eq '"bad host"' "$(jq -c .error <<<"$body")" "host refusal explains the error"
}

test_bookmark_after_branch_deleted() {
  local commit
  commit=$(git -C "$REPO" rev-parse refs/heads/factory/001-a)
  git -C "$REPO" switch -q main
  git -C "$REPO" update-ref refs/factory/jobs/001-a "$commit"
  git -C "$REPO" branch -D factory/001-a >/dev/null
  assert_eq bookmark "$(get '/api/changes?job=001-a' | jq -r .source)" "falls back to refs/factory/jobs"
  assert_contains "$(get '/api/diff?job=001-a&task=b-1.1')" '+++ b/b.txt' "task diff from the bookmark"
}

test_remote_fallback() {
  local commit
  commit=$(git -C "$REPO" rev-parse refs/factory/jobs/001-a)
  git -C "$REPO" update-ref -d refs/factory/jobs/001-a
  git -C "$REPO" update-ref refs/remotes/origin/factory/001-a "$commit"
  assert_eq remote "$(get '/api/changes?job=001-a' | jq -r .source)" "falls back to the remote job ref"
}

test_merged_landing() {
  cat >"$J/job.json" <<'EOF'
{"id":"001-a","stage":"merged","bead":"b-1","pr":"https://github.com/example/repo/pull/7","tasks":[{"id":"b-1.1"},{"id":"b-1.10"}]}
EOF
  printf 'landed\n' >"$REPO/landing.txt"
  git -C "$REPO" add landing.txt
  git -C "$REPO" commit -q -m 'b-1: A (#7)'
  local c
  c=$(get '/api/changes?job=001-a')
  assert_eq landing "$(jq -r .job.kind <<<"$c")" "finds the squash landing commit on main"
  assert_eq landing.txt "$(jq -r .job.files[0].path <<<"$c")" "uses the landing commit's first-parent change"
  assert_contains "$(get '/api/diff?job=001-a')" '+++ b/landing.txt' "whole landing diff"
  assert_contains "$(get "/api/diff?job=001-a&commit=$(jq -r .job.commit <<<"$c")")" '+++ b/landing.txt' "diff accepts this job's landing commit"
}

test_local_merge_landing() {
  cat >"$J/job.json" <<'EOF'
{"id":"001-a","stage":"merged","bead":"b-2","tasks":[{"id":"b-1.1"},{"id":"b-1.10"}]}
EOF
  git -C "$REPO" switch -q -c factory/001-a
  printf 'local landing\n' >"$REPO/local-landing.txt"
  git -C "$REPO" add local-landing.txt
  git -C "$REPO" commit -q -m 'local change'
  git -C "$REPO" switch -q main
  git -C "$REPO" merge --no-ff --no-edit factory/001-a >/dev/null
  local c
  c=$(get '/api/changes?job=001-a')
  assert_eq landing "$(jq -r .job.kind <<<"$c")" "finds the local-land merge subject"
  assert_eq local-landing.txt "$(jq -r .job.files[0].path <<<"$c")" "uses the merge commit's first-parent change"
}

test_bead_landing_fallback() {
  cat >"$J2/job.json" <<'EOF'
{"id":"002-b","stage":"merged","bead":"b-3","tasks":[]}
EOF
  printf 'bead landing\n' >"$REPO/bead-landing.txt"
  git -C "$REPO" add bead-landing.txt
  git -C "$REPO" commit -q -m 'b-3: final landing'
  local c
  c=$(get '/api/changes?job=002-b')
  assert_eq landing "$(jq -r .job.kind <<<"$c")" "finds a landing by bead subject prefix"
  assert_eq bead-landing.txt "$(jq -r .job.files[0].path <<<"$c")" "uses the bead landing change"
}

test_refuses() {
  local u="http://127.0.0.1:$PORT/api/diff?job=001-a"
  assert_eq 400 "$(code "$u&task=nope")" "unknown task id"
  assert_eq 400 "$(code "$u&commit=HEAD")" "commit must be hex"
  assert_eq 400 "$(code "$u&commit=--output=x")" "no option injection"
  assert_eq 404 "$(code "$u&commit=deadbeef")" "commit not in this job"
  assert_eq 404 "$(code "http://127.0.0.1:$PORT/api/diff?job=../x")" "bad job id"
  assert_eq 404 "$(code "http://127.0.0.1:$PORT/api/changes?job=001..-a")" "job ids containing two dots are refused"
}

test_truncated() {
  stop_server
  start_server "$F" 50
  curl -s -D "$TEST_TMP/headers" -o "$TEST_TMP/body" \
    "http://127.0.0.1:$PORT/api/diff?job=001-a"
  assert_contains "$(tr '[:upper:]' '[:lower:]' <"$TEST_TMP/headers")" 'x-diff-truncated: 1' "truncated diff header"
  assert_contains "$(cat "$TEST_TMP/body")" 'diff truncated' "truncated diff notice"
}

test_no_commit() {
  cat >"$J/job.json" <<'EOF'
{"id":"001-a","stage":"merged","bead":"b-1","pr":"https://github.com/example/repo/pull/7","tasks":[{"id":"b-1.1"},{"id":"b-1.10"},{"id":"b-1.2"}]}
EOF
  local url="http://127.0.0.1:$PORT/api/diff?job=001-a&task=b-1.2"
  assert_eq 404 "$(code "$url")" "task with no commit is unavailable"
  assert_contains "$(get '/api/diff?job=001-a&task=b-1.2')" 'Task commits are no longer available for this job' "explains the unavailable task commit"
}

test_not_a_repo() {
  local outside="$TEST_TMP/outside/factory"
  mkdir -p "$TEST_TMP/outside"
  cp -R "$FACTORY_SRC" "$outside"
  rm -rf "$outside/jobs" "$outside/settings.json"
  mkdir -p "$outside/jobs/001-a"
  echo '{"id":"001-a","stage":"review","tasks":[]}' >"$outside/jobs/001-a/job.json"
  stop_server
  start_server "$outside"
  assert_eq 200 "$(code "http://127.0.0.1:$PORT/api/changes?job=001-a")" "non-repository changes are still available"
  assert_eq null "$(get '/api/changes?job=001-a' | jq -r .source)" "non-repository job has no Git source"
  assert_eq 404 "$(code "http://127.0.0.1:$PORT/api/diff?job=001-a")" "non-repository job has no diff"
}

for t in test_task_commits test_renamed_and_non_ascii_paths_match_page_diff test_git_diff_disables_textconv \
  test_host_check test_bookmark_after_branch_deleted test_remote_fallback \
  test_merged_landing test_local_merge_landing test_bead_landing_fallback \
  test_refuses test_truncated test_no_commit test_not_a_repo; do
  "$t"
done
finish
