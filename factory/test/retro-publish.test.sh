#!/usr/bin/env bash
# Tests for factory/bin/retro-publish. Real git, set up by retro-prep; gh is a
# stub that answers `pr create` with $URL in the target repo and $SRC_URL in
# the factory source (failing while $STUBS/fail-create exists), `pr view` with
# $OLD_BODY, and logs every call (with its directory) to gh.calls.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

URL=https://github.com/o/r/pull/7
SRC_URL=https://github.com/o/ai-factory/pull/9
export URL SRC_URL SRC_REAL='' OLD_BODY=''

# setup [settings-json]: target repo $R with job folder $JOB (id 001-a), the
# gh stub, and retro-prep run (worktrees in $RW and $FW).
setup() {
  R=$(mkrepo)
  [ -n "${1:-}" ] && printf '%s' "$1" >"$R/factory/settings.json"
  JOB="$R/factory/jobs/001-a"
  mkdir -p "$JOB" && JOB=$(cd "$JOB" && pwd)
  echo '{"id":"001-a","stage":"merged"}' >"$JOB/job.json"
  mkstub
  prep
}

mkstub() {
  rm -f "$STUBS"/*.calls
  # shellcheck disable=SC2016 # expands in the stub
  stub gh 'pwd -P >>"$STUBS/gh.dirs"
case "$*" in
  "pr list"*) echo "[]" ;;
  "label create"*) ;;
  "pr create"*)
    [ -e "$STUBS/fail-create" ] && exit 1
    if [ -n "$SRC_REAL" ] && [ "$(pwd -P)" = "$SRC_REAL" ]; then echo "$SRC_URL"; else echo "$URL"; fi ;;
  "pr view"*) printf "%s\n" "$OLD_BODY" ;;
  "pr edit"*) ;;
  "pr comment"*) ;;
  *) echo "unexpected gh $*" >&2; exit 99 ;;
esac'
}

# prep: runs retro-prep, sets $RW and $FW, then clears the gh log.
prep() {
  local out
  out=$("$R/factory/bin/retro-prep" "$JOB") || _fail "retro-prep failed"
  RW=$(printf '%s\n' "$out" | awk '$1 == "repo" {print $2}')
  FW=$(printf '%s\n' "$out" | awk '$1 == "factory" {print $2}')
  rm -f "$STUBS/gh.calls" "$STUBS/gh.dirs"
}

# mksrc: a second repo $SRC playing the ai-factory checkout, wired into settings.
mksrc() {
  SRC=$(mkrepo)
  SRC_REAL=$(cd "$SRC" && pwd -P)
  printf '{"factory_source":"%s"}' "$SRC" >"$R/factory/settings.json"
}

# role <first-line>: writes retro.md and both PR bodies, as the role would.
role() {
  printf '%s\n\nbody\n' "$1" >"$JOB/retro.md"
  echo 'repo pr body' >"$JOB/retro-pr-repo.md"
  echo 'factory pr body' >"$JOB/retro-pr-factory.md"
}
lesson() { printf '## Lessons from factory jobs\n\n- check the CDK (job 001-a)\n' >>"$RW/AGENTS.md"; }

P() { "$R/factory/bin/retro-publish" "$JOB"; }
j() { jq -r "$1" "$JOB/job.json"; }
calls() { cat "$STUBS/gh.calls" 2>/dev/null; }
exists() { [ -e "$1" ] && echo yes || echo no; }
remote_head() { git -C "$1" ls-remote -q origin "refs/heads/$2" | awk '{print $1}'; }

test_opens_repo_pr() {
  setup; role 'RETRO: 2 fixes'; lesson
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "repo pr: exit 0"
  assert_contains "$(calls | grep '^pr create')" "--label factory-retro" "repo pr: label"
  assert_contains "$(calls | grep '^pr create')" "--title Retro\\ 001-a:\\ 2\\ lessons" "repo pr: title"
  assert_contains "$(calls | grep '^pr create')" "--base main --head factory/retro-001-a" "repo pr: base and head"
  assert_contains "$(calls | grep '^pr create')" "--body-file $JOB/retro-pr-repo.md" "repo pr: body file"
  assert_eq "$URL" "$(j .retro_pr)" "repo pr: retro_pr set"
  assert_eq "retro 001-a: 2 fixes, $URL, no factory changes" "$OUT" "repo pr: summary line"
  assert_eq "Retro 001-a: 2 lessons" "$(git -C "$R" log -1 --format=%s factory/retro-001-a)" "repo pr: commit message"
  assert_eq "$(git -C "$R" rev-parse factory/retro-001-a)" "$(remote_head "$R" factory/retro-001-a)" "repo pr: pushed"
}

test_label_created_before_pr() {
  setup; role 'RETRO: 1 fixes'; lesson
  P >/dev/null
  label=$(calls | grep -n '^label create factory-retro --force' | cut -d: -f1)
  create=$(calls | grep -n '^pr create' | cut -d: -f1)
  assert_eq yes "$([ -n "$label" ] && [ -n "$create" ] && [ "$label" -lt "$create" ] && echo yes)" "label: created before pr create"
}

test_open_pr_pushes_only() {
  setup; role 'RETRO: 1 fixes'; lesson
  # shellcheck disable=SC2016 # $u is a jq variable
  "$R/factory/bin/job-set" "$JOB/job.json" '.retro_pr = $u' --arg u "$URL"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "open pr: exit 0"
  case $(calls) in *"pr create"*) _fail "open pr: must not create a PR" ;; *) _pass ;; esac
  assert_eq "$(git -C "$R" rev-parse factory/retro-001-a)" "$(remote_head "$R" factory/retro-001-a)" "open pr: pushed"
  assert_eq "retro 001-a: 1 fixes, $URL, no factory changes" "$OUT" "open pr: summary line"
}

test_nothing_to_change() {
  setup; role 'RETRO: nothing to change'
  before=$(git -C "$RW" rev-parse HEAD)
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "nothing: exit 0"
  assert_eq "" "$(calls)" "nothing: no gh calls"
  assert_eq "retro 001-a: 0 fixes, no repo changes, no factory changes" "$OUT" "nothing: summary line"
  assert_eq "$before" "$(git -C "$R" rev-parse origin/main)" "nothing: worktree was at base"
  assert_eq "" "$(remote_head "$R" factory/retro-001-a)" "nothing: nothing pushed"
}

test_empty_branch_deleted() {
  setup; role 'RETRO: nothing to change'
  P >/dev/null
  assert_eq no "$(git -C "$R" rev-parse -q --verify refs/heads/factory/retro-001-a >/dev/null && echo yes || echo no)" "empty: branch deleted"
  prep
  assert_eq factory/retro-001-a "$(git -C "$RW" branch --show-current)" "empty: next prep reuses the name"
}

test_branch_with_commits_kept() {
  setup '{"land":"local"}'; role 'RETRO: 1 fixes'; lesson
  P >/dev/null
  prep; role 'RETRO: nothing to change'
  P >/dev/null
  assert_eq yes "$(git -C "$R" rev-parse -q --verify refs/heads/factory/retro-001-a >/dev/null && echo yes || echo no)" "kept: branch with a lesson survives an empty re-run"
}

test_local_mode_branch_only() {
  setup '{"land":"local"}'; role 'RETRO: 1 fixes'; lesson
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "local: exit 0"
  assert_eq no "$(exists "$STUBS/gh.calls")" "local: gh never called"
  assert_eq "retro 001-a: 1 fixes, branch factory/retro-001-a, no factory changes" "$OUT" "local: summary line"
  assert_contains "$(git -C "$R" show factory/retro-001-a:AGENTS.md)" "(job 001-a)" "local: branch has the commit"
  assert_eq "" "$(remote_head "$R" factory/retro-001-a)" "local: nothing pushed"
}

test_installed_patch() {
  setup; role 'RETRO: 1 fixes'
  echo 'new rule' >"$FW/factory/agents/x.md"
  echo '# tweak' >>"$FW/factory/bin/job-set"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "patch: exit 0"
  assert_eq "# Against the factory installed in $(cd "$R" && pwd), not ai-factory's main." "$(head -n1 "$JOB/retro-factory.patch" 2>/dev/null)" "patch: first line"
  assert_contains "$(cat "$JOB/retro-factory.patch" 2>/dev/null)" "+new rule" "patch: new file included"
  assert_contains "$(cat "$JOB/retro-factory.patch" 2>/dev/null)" "+# tweak" "patch: edit included"
  assert_eq no "$(exists "$JOB/.retro-factory")" "patch: .retro-factory removed"
  assert_eq "retro 001-a: 1 fixes, no repo changes, patch $JOB/retro-factory.patch" "$OUT" "patch: summary line"
  assert_eq "" "$(calls)" "patch: no gh calls"
}

test_factory_pr_and_comment() {
  R=$(mkrepo)
  JOB="$R/factory/jobs/001-a"
  mkdir -p "$JOB" && JOB=$(cd "$JOB" && pwd)
  echo '{"id":"001-a","stage":"merged"}' >"$JOB/job.json"
  mksrc
  printf '{"factory_source":"%s","land":"local"}' "$SRC" >"$R/factory/settings.json"
  mkstub; prep; role 'RETRO: 1 fixes'
  echo 'new rule' >>"$FW/factory/agents/x.md"
  echo 'same again, job 001-a' >"$JOB/retro-comment-12.md"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "source: exit 0"
  assert_contains "$(calls | grep '^pr create')" "--head retro/work-001-a" "source: PR head"
  assert_contains "$(calls | grep '^pr create')" "--body-file $JOB/retro-pr-factory.md" "source: factory body"
  assert_contains "$(calls | grep '^pr create')" "--title Retro\\ work\\ 001-a:\\ 1\\ fixes" "source: factory title"
  assert_eq 1 "$(calls | grep -c '^pr create')" "source: only the factory PR (land local)"
  assert_eq "$SRC_REAL" "$(sed -n "$(calls | grep -n '^pr create' | cut -d: -f1)p" "$STUBS/gh.dirs")" "source: gh ran in the source"
  assert_contains "$(calls)" "pr comment 12 --body-file $JOB/retro-comment-12.md" "source: comment posted"
  assert_eq "no yes" "$(exists "$JOB/retro-comment-12.md") $(exists "$JOB/retro-comment-12.posted.md")" "source: comment file renamed"
  assert_eq "$SRC_URL" "$(j .retro_factory_pr)" "source: retro_factory_pr set"
  assert_eq "retro 001-a: 1 fixes, no repo changes, $SRC_URL" "$OUT" "source: summary line"
  assert_eq "$(git -C "$SRC" rev-parse retro/work-001-a)" "$(remote_head "$SRC" retro/work-001-a)" "source: pushed"
  assert_eq no "$(exists "$FW")" "source: factory worktree removed"
}

test_comment_posted_once() {
  R=$(mkrepo)
  JOB="$R/factory/jobs/001-a"
  mkdir -p "$JOB" && JOB=$(cd "$JOB" && pwd)
  echo '{"id":"001-a","stage":"merged"}' >"$JOB/job.json"
  mksrc; mkstub; prep; role 'RETRO: nothing to change'
  echo 'evidence' >"$JOB/retro-comment-12.md"
  P >/dev/null
  rm -f "$STUBS/gh.calls"
  P >/dev/null; rc=$?
  assert_eq 0 "$rc" "once: second publish exit 0"
  case $(calls) in *"pr comment"*) _fail "once: comment posted twice" ;; *) _pass ;; esac
}

test_bad_first_line() {
  setup; printf 'hello\n' >"$JOB/retro.md"; lesson
  assert_exit 1 "bad line: exit 1" -- P
  assert_eq "$RW" "$(j .retro_worktree)" "bad line: job.json untouched"
  printf 'RETRO: some fixes\n' >"$JOB/retro.md"
  assert_exit 1 "bad count: exit 1" -- P
  rm -f "$JOB/retro.md"
  assert_exit 1 "no retro.md: exit 1" -- P
}

test_missing_body() {
  setup; role 'RETRO: 1 fixes'; lesson
  rm -f "$JOB/retro-pr-repo.md"
  assert_exit 1 "no body: exit 1" -- P
  assert_eq "" "$(calls | grep '^pr create')" "no body: no pr create"
}

test_missing_factory_body() {
  R=$(mkrepo)
  JOB="$R/factory/jobs/001-a"
  mkdir -p "$JOB" && JOB=$(cd "$JOB" && pwd)
  echo '{"id":"001-a","stage":"merged"}' >"$JOB/job.json"
  mksrc; mkstub; prep; role 'RETRO: 2 fixes'; lesson
  echo 'new rule' >>"$FW/factory/agents/x.md"
  rm -f "$JOB/retro-pr-factory.md"
  assert_exit 1 "no factory body: exit 1" -- P
  assert_eq "" "$(calls)" "no factory body: no gh calls"
  assert_eq "$(git -C "$R" rev-parse origin/main)" "$(git -C "$RW" rev-parse HEAD)" "no factory body: repo side not committed"
  assert_contains "$(git -C "$RW" status --porcelain)" "AGENTS.md" "no factory body: repo edit still pending"
  assert_eq "" "$(remote_head "$R" factory/retro-001-a)" "no factory body: repo side not pushed"
  assert_eq "$RW" "$(j .retro_worktree)" "no factory body: job.json untouched"
}

test_stale_patch_removed() {
  setup; role 'RETRO: nothing to change'
  echo old >"$JOB/retro-factory.patch"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "stale patch: exit 0"
  assert_eq no "$(exists "$JOB/retro-factory.patch")" "stale patch: removed"
  assert_eq "retro 001-a: 0 fixes, no repo changes, no factory changes" "$OUT" "stale patch: summary line"
}

test_push_failure_recovers() {
  setup; role 'RETRO: 1 fixes'; lesson
  good=$(git -C "$R" remote get-url origin)
  git -C "$R" remote set-url origin "$TEST_TMP/missing.git"
  P >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "push fail: exit 1"
  assert_eq yes "$(exists "$RW")" "push fail: worktree kept"
  assert_eq "$RW" "$(j .retro_worktree)" "push fail: job.json untouched"
  assert_eq null "$(j .retro_pr)" "push fail: no retro_pr"
  git -C "$R" remote set-url origin "$good"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "push fail: re-run exit 0"
  assert_eq "retro 001-a: 1 fixes, $URL, no factory changes" "$OUT" "push fail: re-run opens the PR"
  assert_eq "$(git -C "$R" rev-parse factory/retro-001-a)" "$(remote_head "$R" factory/retro-001-a)" "push fail: re-run pushed"
  assert_eq "factory/retro-001-a" "$(retro_branches)" "push fail: no -2 branch or orphan"
}

# retro_branches: every factory/retro-* branch, local and on origin, deduped.
retro_branches() {
  { git -C "$R" for-each-ref --format='%(refname:short)' 'refs/heads/factory/retro-*'
    git -C "$R" ls-remote -q --heads origin 'factory/retro-*' | sed 's|.*refs/heads/||'; } | sort -u | tr '\n' ' ' | sed 's/ $//'
}

test_pr_create_failure_recovers() {
  setup; role 'RETRO: 1 fixes'; lesson
  touch "$STUBS/fail-create"
  P >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "create fail: exit 1"
  assert_eq "$RW" "$(j .retro_worktree)" "create fail: job.json untouched"
  assert_eq null "$(j .retro_pr)" "create fail: no retro_pr"
  assert_eq "$(git -C "$R" rev-parse factory/retro-001-a)" "$(remote_head "$R" factory/retro-001-a)" "create fail: branch was pushed"
  rm -f "$STUBS/fail-create"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "create fail: re-run exit 0"
  assert_eq "retro 001-a: 1 fixes, $URL, no factory changes" "$OUT" "create fail: re-run opens the PR"
  assert_eq "$URL" "$(j .retro_pr)" "create fail: retro_pr set"
  assert_eq "factory/retro-001-a" "$(retro_branches)" "create fail: no -2 branch or orphan"
}

test_reprep_after_failed_push() {
  setup; role 'RETRO: 1 fixes'; lesson
  good=$(git -C "$R" remote get-url origin)
  git -C "$R" remote set-url origin "$TEST_TMP/missing.git"
  P >/dev/null 2>&1
  head=$(git -C "$R" rev-parse factory/retro-001-a)
  git -C "$R" remote set-url origin "$good"
  prep
  assert_eq factory/retro-001-a "$(git -C "$RW" branch --show-current)" "reprep push: unpublished branch reused"
  assert_eq "$head" "$(git -C "$RW" rev-parse HEAD)" "reprep push: its commit kept"
  role 'RETRO: 1 fixes'
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "reprep push: publish exit 0"
  assert_eq "retro 001-a: 1 fixes, $URL, no factory changes" "$OUT" "reprep push: PR opened"
  assert_eq "factory/retro-001-a" "$(retro_branches)" "reprep push: no -2 branch or orphan"
}

test_reprep_after_failed_create() {
  setup; role 'RETRO: 1 fixes'; lesson
  touch "$STUBS/fail-create"
  P >/dev/null 2>&1
  rm -f "$STUBS/fail-create"
  head=$(git -C "$R" rev-parse factory/retro-001-a)
  prep
  assert_eq factory/retro-001-a "$(git -C "$RW" branch --show-current)" "reprep create: pushed branch reused"
  assert_eq "$head" "$(git -C "$RW" rev-parse HEAD)" "reprep create: its commit kept"
  role 'RETRO: 1 fixes'
  OUT=$(P); rc=$?
  assert_eq "retro 001-a: 1 fixes, $URL, no factory changes" "$OUT" "reprep create: PR opened"
  assert_eq "factory/retro-001-a" "$(retro_branches)" "reprep create: no -2 branch or orphan"
}

test_existing_pr_url_printed() {
  setup; role 'RETRO: nothing to change'
  OLD_BODY='repo pr body'
  # shellcheck disable=SC2016 # $u is a jq variable
  "$R/factory/bin/job-set" "$JOB/job.json" '.retro_pr = $u' --arg u "$URL"
  OUT=$(P); rc=$?
  OLD_BODY=''
  assert_eq 0 "$rc" "existing pr: exit 0"
  assert_eq "retro 001-a: 0 fixes, $URL, no factory changes" "$OUT" "existing pr: url printed with nothing new"
  case $(calls) in *"pr edit"*) _fail "existing pr: unchanged body not edited" ;; *) _pass ;; esac
}

test_pr_body_edited() {
  R=$(mkrepo)
  JOB="$R/factory/jobs/001-a"
  mkdir -p "$JOB" && JOB=$(cd "$JOB" && pwd)
  echo '{"id":"001-a","stage":"merged"}' >"$JOB/job.json"
  mksrc; mkstub; prep; role 'RETRO: 2 fixes'; lesson
  echo 'new rule' >>"$FW/factory/agents/x.md"
  # shellcheck disable=SC2016 # $u and $f are jq variables
  "$R/factory/bin/job-set" "$JOB/job.json" '.retro_pr = $u | .retro_factory_pr = $f' --arg u "$URL" --arg f "$SRC_URL"
  OLD_BODY='old body'
  OUT=$(P); rc=$?
  OLD_BODY=''
  assert_eq 0 "$rc" "edit: exit 0"
  assert_contains "$(calls)" "pr edit $URL --body-file $JOB/retro-pr-repo.md" "edit: repo PR body updated"
  assert_contains "$(calls)" "pr edit $SRC_URL --body-file $JOB/retro-pr-factory.md" "edit: factory PR body updated"
  assert_eq "$SRC_REAL" "$(sed -n "$(calls | grep -n "^pr edit $SRC_URL" | cut -d: -f1)p" "$STUBS/gh.dirs")" "edit: factory edit ran in the source"
  case $(calls) in *"pr create"*) _fail "edit: no new PR" ;; *) _pass ;; esac
}

test_titles_count_kinds() {
  R=$(mkrepo)
  JOB="$R/factory/jobs/001-a"
  mkdir -p "$JOB" && JOB=$(cd "$JOB" && pwd)
  echo '{"id":"001-a","stage":"merged"}' >"$JOB/job.json"
  mksrc; mkstub; prep; role x
  cat >"$JOB/retro.md" <<'MD'
RETRO: 4 fixes

## What each extra attempt was for
- round 2: 1. kind: factory. not a fix line

## Fixes
1. kind: repo. File: AGENTS.md
   - Change: a
2. kind: factory. File: factory/agents/reviewer.md
   - Change: b
3. kind: repo. File: docs/x.md
   - Change: c
4. kind: work. File: src/y
   - Change: d
- No fix for `flaky`: none.

## Repeats
None.
MD
  lesson; echo 'new rule' >>"$FW/factory/agents/x.md"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "kinds: exit 0"
  assert_contains "$(calls)" "--title Retro\\ 001-a:\\ 2\\ lessons" "kinds: repo title counts kind repo"
  assert_contains "$(calls)" "--title Retro\\ work\\ 001-a:\\ 1\\ fixes" "kinds: factory title counts kind factory"
  assert_eq "Retro 001-a: 2 lessons" "$(git -C "$R" log -1 --format=%s factory/retro-001-a)" "kinds: repo commit message"
  assert_eq "Retro work 001-a: 1 fixes" "$(git -C "$SRC" log -1 --format=%s retro/work-001-a)" "kinds: factory commit message"
  assert_contains "$OUT" "retro 001-a: 4 fixes, " "kinds: summary keeps the total"
}

test_worktrees_removed() {
  setup; role 'RETRO: 1 fixes'; lesson
  echo 'new rule' >"$FW/factory/agents/x.md"
  P >/dev/null
  assert_eq "no no" "$(exists "$RW") $(exists "$FW")" "removed: both paths gone"
  assert_eq "null null" "$(j .retro_worktree) $(j .retro_factory_worktree)" "removed: job.json fields null"
  assert_eq yes "$(git -C "$R" rev-parse -q --verify refs/heads/factory/retro-001-a >/dev/null && echo yes)" "removed: branch kept"
  case $(git -C "$R" worktree list) in *retro-001-a*) _fail "removed: worktree still registered" ;; *) _pass ;; esac
}

test_usage() {
  R=$(mkrepo)
  assert_exit 2 "no args: exit 2" -- "$R/factory/bin/retro-publish"
  assert_exit 2 "no job.json: exit 2" -- "$R/factory/bin/retro-publish" "$TEST_TMP"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
