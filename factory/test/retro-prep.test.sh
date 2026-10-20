#!/usr/bin/env bash
# Tests for factory/bin/retro-prep. Real git; gh is a stub that answers
# `pr list` with $PRS in the target repo and $SRC_PRS in the factory source.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

URL=https://github.com/o/r/pull/5
export PRS='[]' SRC_PRS='[]' SRC_REAL=''

# pr <state> <headRefName> [body]: one gh pr list entry as JSON.
pr() {
  jq -cn --arg s "$1" --arg h "$2" --arg b "${3:-}" --arg u "$URL" \
    '{number: 5, title: "Retro 001-a: 1 lessons", state: $s, url: $u, headRefName: $h, body: $b}'
}

# setup [settings-json]: target repo $R with job folder $JOB (id 001-a).
setup() {
  R=$(mkrepo)
  [ -n "${1:-}" ] && printf '%s' "$1" >"$R/factory/settings.json"
  JOB="$R/factory/jobs/001-a"
  mkdir -p "$JOB" && JOB=$(cd "$JOB" && pwd)
  echo '{"id":"001-a","stage":"merged"}' >"$JOB/job.json"
  PRS='[]' SRC_PRS='[]'
  rm -f "$STUBS"/*.calls
  # shellcheck disable=SC2016 # expands in the stub
  stub gh 'case "$*" in
  "pr list"*)
    if [ -n "$SRC_REAL" ] && [ "$(pwd -P)" = "$SRC_REAL" ]; then echo "$SRC_PRS"; else echo "$PRS"; fi ;;
  *) echo "unexpected gh $*" >&2; exit 99 ;;
esac'
  return 0
}

# mksrc: a second repo $SRC playing the ai-factory checkout, with SKILL.md pushed.
mksrc() {
  SRC=$(mkrepo)
  mkdir -p "$SRC/.claude/skills/factory"
  echo skill >"$SRC/.claude/skills/factory/SKILL.md"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m skill && git -C "$SRC" push -q origin main 2>/dev/null
  SRC_REAL=$(cd "$SRC" && pwd -P)
}

P() { "$R/factory/bin/retro-prep" "$JOB"; }
wt() { printf '%s\n' "$OUT" | awk -v k="$1" '$1 == k {print $2}'; }
j() { jq -r "$1" "$JOB/job.json"; }

# push_branch <repo> <branch>: pushes <branch> with one extra commit via a clone.
push_branch() {
  local c
  c=$(mktemp -d "$TEST_TMP/clone.XXXXXX")
  {
    git clone -q "$(git -C "$1" remote get-url origin)" "$c" &&
      git -C "$c" checkout -q -b "$2" &&
      echo extra >"$c/extra.txt" &&
      git -C "$c" add -A &&
      git -C "$c" commit -q -m extra &&
      git -C "$c" push -q origin "$2"
  } >/dev/null 2>&1
  git -C "$c" rev-parse HEAD
}

test_new_branch_from_base() {
  setup
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "new: exit 0"
  assert_contains "$(printf '%s\n' "$OUT" | sed -n 1p)" "repo " "new: first line is repo"
  assert_contains "$(wt repo)" "/work-factory/retro-001-a" "new: repo worktree path"
  assert_eq "factory $JOB/.retro-factory installed" "$(printf '%s\n' "$OUT" | sed -n 2p)" "new: factory line installed"
  assert_eq factory/retro-001-a "$(git -C "$(wt repo)" branch --show-current)" "new: branch name"
  assert_eq "$(git -C "$R" rev-parse origin/main)" "$(git -C "$(wt repo)" rev-parse HEAD)" "new: at origin/main"
  assert_eq null "$(j .retro_pr)" "new: retro_pr null"
  assert_eq null "$(j .retro_factory_pr)" "new: retro_factory_pr null"
  assert_eq installed "$(j .retro_factory_kind)" "new: kind installed"
  assert_eq "$(wt repo)" "$(j .retro_worktree)" "new: retro_worktree"
  assert_eq "$JOB/.retro-factory" "$(j .retro_factory_worktree)" "new: retro_factory_worktree"
  assert_eq yes "$([ -f "$JOB/.retro-factory/factory/bin/job-set" ] && [ -f "$JOB/.retro-factory/factory/models.json" ] && echo yes)" "new: installed files copied"
  assert_eq installed "$(git -C "$JOB/.retro-factory" log -1 --format=%s)" "new: installed copy committed"
  assert_eq "" "$(git -C "$R" status --porcelain -- . ':!factory/')" "new: main checkout untouched"
  assert_eq no "$([ -e "$JOB/retro-rejected.md" ] && echo yes || echo no)" "new: no retro-rejected.md"
}

test_open_pr_reused() {
  setup
  head=$(push_branch "$R" factory/retro-001-a)
  PRS="[$(pr OPEN factory/retro-001-a)]"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "open: exit 0"
  assert_eq "$head" "$(git -C "$(wt repo)" rev-parse HEAD)" "open: worktree on the PR's commit"
  assert_eq factory/retro-001-a "$(git -C "$(wt repo)" branch --show-current)" "open: branch reused"
  assert_eq "$URL" "$(j .retro_pr)" "open: retro_pr is the url"
}

test_merged_pr_next_branch() {
  setup
  push_branch "$R" factory/retro-001-a >/dev/null
  git -C "$R" fetch -q origin
  PRS="[$(pr MERGED factory/retro-001-a)]"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "merged: exit 0"
  assert_eq factory/retro-001-a-2 "$(git -C "$(wt repo)" branch --show-current)" "merged: next branch"
  assert_eq "$(git -C "$R" rev-parse origin/main)" "$(git -C "$(wt repo)" rev-parse HEAD)" "merged: from origin/main"
  assert_eq null "$(j .retro_pr)" "merged: retro_pr null"
}

test_closed_pr_rejected() {
  setup
  PRS="[$(pr CLOSED factory/retro-001-a 'drop the CDK lesson'),$(pr CLOSED factory/retro-009-z 'other job')]"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "closed: exit 0"
  assert_contains "$(cat "$JOB/retro-rejected.md" 2>/dev/null)" "## $URL" "closed: url heading"
  assert_contains "$(cat "$JOB/retro-rejected.md" 2>/dev/null)" "drop the CDK lesson" "closed: body kept"
  case $(cat "$JOB/retro-rejected.md" 2>/dev/null) in *"other job"*) _fail "closed: other job's PR included" ;; *) _pass ;; esac
  assert_eq factory/retro-001-a-2 "$(git -C "$(wt repo)" branch --show-current)" "closed: next branch"
  PRS='[]'
  P >/dev/null
  assert_eq no "$([ -e "$JOB/retro-rejected.md" ] && echo yes || echo no)" "closed: file removed when none"
}

test_local_mode() {
  setup '{"land":"local"}'
  git -C "$R" branch -q factory/retro-001-a
  w="$TEST_TMP/lw"
  git -C "$R" worktree add -q "$w" factory/retro-001-a 2>/dev/null
  echo lesson >"$w/AGENTS.md" && git -C "$w" add -A && git -C "$w" commit -q -m lesson
  head=$(git -C "$w" rev-parse HEAD)
  git -C "$R" worktree remove --force "$w"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "local: exit 0"
  assert_eq no "$([ -e "$STUBS/gh.calls" ] && echo yes || echo no)" "local: gh never called"
  assert_eq factory/retro-001-a "$(git -C "$(wt repo)" branch --show-current)" "local: unmerged branch reused"
  assert_eq "$head" "$(git -C "$(wt repo)" rev-parse HEAD)" "local: branch head kept"
  git -C "$R" merge -q factory/retro-001-a
  OUT=$(P)
  assert_eq factory/retro-001-a-2 "$(git -C "$(wt repo)" branch --show-current)" "local: merged branch skipped"
  assert_eq "$(git -C "$R" rev-parse main)" "$(git -C "$(wt repo)" rev-parse HEAD)" "local: new branch from main"
}

test_factory_source() {
  setup; mksrc
  printf '{"factory_source":"%s"}' "$SRC" >"$R/factory/settings.json"
  SRC_PRS="[$(pr OPEN retro/other-009-z)]"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "source: exit 0"
  f=$(wt factory)
  assert_contains "$f" "/work-factory/retro-work-001-a" "source: worktree path"
  assert_eq source "$(printf '%s\n' "$OUT" | sed -n 2p | awk '{print $3}')" "source: line ends source"
  assert_eq retro/work-001-a "$(git -C "$f" branch --show-current)" "source: branch name"
  assert_eq "$(git -C "$SRC" rev-parse origin/main)" "$(git -C "$f" rev-parse HEAD)" "source: at source origin/main"
  assert_eq 1 "$(jq length "$JOB/retro-factory-prs.json" 2>/dev/null)" "source: retro-factory-prs.json is valid JSON"
  assert_eq source "$(j .retro_factory_kind)" "source: kind"
  assert_eq null "$(j .retro_factory_pr)" "source: other job's open PR not reused"
  assert_eq no "$([ -e "$JOB/.retro-factory" ] && echo yes || echo no)" "source: no installed copy"
}

test_stale_install() {
  setup; mksrc
  printf '{"factory_source":"%s"}' "$SRC" >"$R/factory/settings.json"
  echo '# local tweak' >>"$R/factory/bin/job-set"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "stale: exit 0"
  assert_contains "$(cat "$JOB/retro-stale.txt" 2>/dev/null)" "job-set" "stale: names job-set"
}

test_stale_worktree_replaced() {
  setup
  P >/dev/null
  echo junk >"$JOB/.retro-factory/junk"
  OUT=$(P); rc=$?
  assert_eq 0 "$rc" "rerun: exit 0"
  assert_eq no "$([ -e "$JOB/.retro-factory/junk" ] && echo yes || echo no)" "rerun: installed copy rebuilt"
}

test_bad_source() {
  setup
  mkdir -p "$TEST_TMP/notgit"
  printf '{"factory_source":"%s"}' "$TEST_TMP/notgit" >"$R/factory/settings.json"
  assert_exit 1 "bad source: exit 1" -- P
}

test_usage() {
  setup
  assert_exit 2 "no args: exit 2" -- "$R/factory/bin/retro-prep"
  assert_exit 2 "no job.json: exit 2" -- "$R/factory/bin/retro-prep" "$TEST_TMP"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
