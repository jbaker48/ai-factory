#!/usr/bin/env bash
# Tests for factory/bin/agents-md: apply merges factory sections into a scratch
# AGENTS.md; check runs commands in a fresh worktree of a scratch repo.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
AMD=$FACTORY_SRC/bin/agents-md

test_apply_replaces_factory_section_keeps_user_text() {
  local d=$TEST_TMP/apply1
  mkdir -p "$d"
  cat >"$d/AGENTS.md" <<'MD'
# Proj

My own intro.

<!-- factory:begin setup -->
## Setup

old setup
<!-- factory:end setup -->

## Deploying

Ask Sam first.
MD
  cat >"$d/new.md" <<'MD'
<!-- factory:begin setup -->
## Setup

npm ci
<!-- factory:end setup -->
MD
  assert_exit 0 "apply exits 0" -- "$AMD" apply "$d/AGENTS.md" "$d/new.md"
  assert_eq "# Proj

My own intro.

<!-- factory:begin setup -->
## Setup

npm ci
<!-- factory:end setup -->

## Deploying

Ask Sam first." "$(cat "$d/AGENTS.md")" "setup section replaced in place, user text unchanged"
}

test_apply_appends_missing_section() {
  local d=$TEST_TMP/apply2
  mkdir -p "$d"
  printf '# Proj\n\nMine.\n' >"$d/AGENTS.md"
  printf '<!-- factory:begin validate -->\n## Validate\n\nnpm test\n<!-- factory:end validate -->\n' >"$d/new.md"
  assert_exit 0 "apply exits 0" -- "$AMD" apply "$d/AGENTS.md" "$d/new.md"
  assert_eq "# Proj

Mine.

<!-- factory:begin validate -->
## Validate

npm test
<!-- factory:end validate -->" "$(cat "$d/AGENTS.md")" "missing section appended after a blank line"
  assert_exit 0 "second apply exits 0" -- "$AMD" apply "$d/AGENTS.md" "$d/new.md"
  assert_eq 1 "$(grep -c 'factory:begin validate' "$d/AGENTS.md")" "a re-run does not append it twice"
  printf '<!-- factory:begin validate -->\nv\n<!-- factory:end validate -->\n<!-- factory:begin layout -->\nl\n<!-- factory:end layout -->\n' >"$d/new.md"
  "$AMD" apply "$d/AGENTS.md" "$d/new.md"
  assert_eq "# Proj

Mine.

<!-- factory:begin validate -->
v
<!-- factory:end validate -->

<!-- factory:begin layout -->
l
<!-- factory:end layout -->" "$(cat "$d/AGENTS.md")" "a section appended after a factory section gets a blank line"
}

test_apply_creates_missing_target() {
  local d=$TEST_TMP/apply3
  mkdir -p "$d"
  printf '<!-- factory:begin intro -->\n# Proj\n<!-- factory:end intro -->\n' >"$d/new.md"
  assert_exit 0 "apply exits 0" -- "$AMD" apply "$d/AGENTS.md" "$d/new.md"
  assert_eq "$(cat "$d/new.md")" "$(cat "$d/AGENTS.md" 2>/dev/null)" "missing AGENTS.md written from the sections"
}

test_apply_refuses_unterminated_section() {
  local d=$TEST_TMP/apply4 before
  mkdir -p "$d"
  printf '# Proj\n\n<!-- factory:begin setup -->\nold\n\n## Mine\n\nkeep me\n' >"$d/AGENTS.md"
  printf '<!-- factory:begin setup -->\nnew\n<!-- factory:end setup -->\n' >"$d/new.md"
  before=$(cat "$d/AGENTS.md")
  assert_exit 1 "unterminated section in AGENTS.md fails" -- "$AMD" apply "$d/AGENTS.md" "$d/new.md"
  assert_eq "$before" "$(cat "$d/AGENTS.md")" "AGENTS.md unchanged after a refused apply"
  printf '# Proj\n' >"$d/AGENTS.md"
  printf '<!-- factory:begin setup -->\nnew\n' >"$d/new.md"
  assert_exit 1 "unterminated section in the sections file fails" -- "$AMD" apply "$d/AGENTS.md" "$d/new.md"
  assert_eq "# Proj" "$(cat "$d/AGENTS.md")" "AGENTS.md unchanged"
}

# target: prints a scratch repo with a tracked file, a gitignored .env in the
# main checkout and an uncommitted AGENTS.md.
target() {
  local d
  d=$(mktemp -d "$TEST_TMP/target.XXXXXX") || return 1
  {
    git init -q -b main "$d" && echo hi >"$d/tracked.txt" && echo .env >"$d/.gitignore" &&
      git -C "$d" add -A && git -C "$d" commit -q -m init && echo SECRET=1 >"$d/.env" &&
      echo '# Proj' >"$d/AGENTS.md"
  } >/dev/null 2>&1 || return 1
  echo "$d"
}

test_check_runs_commands_in_fresh_worktree() {
  local t out code
  t=$(target)
  cat >"$TEST_TMP/cmds" <<'C'
# setup
test -f tracked.txt
test -f .env

test -f AGENTS.md
echo boom >&2; exit 3
C
  out=$("$AMD" check "$t" "$TEST_TMP/cmds" 2>&1)
  code=$?
  assert_eq 1 "$code" "check exits 1 when a command fails"
  assert_contains "$out" "PASS test -f tracked.txt" "tracked files are in the worktree"
  assert_contains "$out" "FAIL (exit 1) test -f .env" "gitignored files are not: the worktree is fresh"
  assert_contains "$out" "PASS test -f AGENTS.md" "the uncommitted AGENTS.md is copied in"
  assert_contains "$out" "FAIL (exit 3) echo boom >&2; exit 3" "every command runs, and its exit is reported"
  assert_contains "$out" "boom" "a failing command's output is shown"
  assert_contains "$out" "2 of 4 commands failed" "summary line counts failures"
  assert_eq 1 "$(git -C "$t" worktree list | wc -l | tr -d ' ')" "the check worktree is removed"
  assert_eq "" "$(git -C "$t" status --porcelain --untracked-files=no)" "the target's tracked files are untouched"
}

test_check_passes_when_all_pass() {
  local t out
  t=$(target)
  printf 'true\ntest -d .\n' >"$TEST_TMP/cmds-ok"
  out=$("$AMD" check "$t" "$TEST_TMP/cmds-ok" 2>&1)
  assert_eq 0 "$?" "check exits 0 when every command passes"
  assert_contains "$out" "all 2 commands passed" "summary line"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
