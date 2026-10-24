#!/usr/bin/env bash
# Shared helpers for factory tests. Source it from a *.test.sh file.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides assert_eq, assert_contains, assert_exit, mkrepo, stub and finish.
# Sourcing it creates a private temp dir, points HOME and git config at it
# (so the real ~/.codex and ~/.claude are never touched), puts $STUBS first
# on PATH, and removes everything on exit. finish prints "N passed, M failed"
# and exits non-zero if anything failed.
set -uo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FACTORY_SRC=$(cd "$LIB_DIR/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/factory-test.XXXXXX") || exit 1
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$TEST_TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
STUBS="$TEST_TMP/stubs"
mkdir -p "$STUBS"
export TEST_TMP STUBS
unset FACTORY_SETTINGS
export PATH="$STUBS:$PATH"

PASSED=0 FAILED=0

_pass() { PASSED=$((PASSED + 1)); }
_fail() { FAILED=$((FAILED + 1)); echo "FAIL: $1" >&2; shift; [ $# -gt 0 ] && printf '  %s\n' "$@" >&2; }

# assert_eq <expected> <actual> <msg>
assert_eq() {
  if [ "$1" = "$2" ]; then _pass; else _fail "$3" "expected: $1" "actual:   $2"; fi
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case $1 in *"$2"*) _pass ;; *) _fail "$3" "missing: $2" "in:      $1" ;; esac
}

# assert_exit <code> <msg> -- <cmd...>   (stdout/stderr of cmd are discarded)
assert_exit() {
  local want=$1 msg=$2
  shift 3
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then _pass; else _fail "$msg" "expected exit $want, got $got"; fi
}

# mkrepo: prints the path of a temp repo with an initial commit on main, a bare
# origin with origin/main fetched, and a copy of this repo's factory/ in it.
mkrepo() {
  local d bare
  d=$(mktemp -d "$TEST_TMP/repo.XXXXXX") || return 1
  bare="$d.origin.git"
  {
    git init -q --bare -b main "$bare" &&
      git init -q -b main "$d/work" &&
      cp -R "$FACTORY_SRC" "$d/work/factory" &&
      rm -rf "$d/work/factory/jobs" "$d/work/factory/settings.json" &&
      cd "$d/work" &&
      echo init >README &&
      git add -A &&
      git commit -q -m init &&
      git remote add origin "$bare" &&
      git push -q -u origin main &&
      git fetch -q origin
  } >/dev/null 2>&1 || return 1
  echo "$d/work"
}

# source_repo: prints the path of a git repo holding a committed copy of this
# checkout's .claude/ and factory/ (working tree, so uncommitted scripts are
# included), for install and upgrade tests.
source_repo() {
  local d root
  root=$(cd "$FACTORY_SRC/.." && pwd)
  d=$(mktemp -d "$TEST_TMP/source.XXXXXX") || return 1
  {
    cp -R "$root/.claude" "$root/factory" "$d/" &&
      rm -rf "$d/factory/settings.json" "$d/.claude/worktrees" &&
      find "$d/factory/jobs" -mindepth 1 ! -name .gitkeep -exec rm -rf {} + &&
      git init -q -b main "$d" && git -C "$d" add -A && git -C "$d" commit -q -m source
  } >/dev/null 2>&1 || return 1
  echo "$d"
}

# stub <name> <body>: writes an executable $STUBS/<name> that logs each call's
# arguments (one line, shell-quoted via %q) to $STUBS/<name>.calls, then runs <body>.
stub() {
  local f="$STUBS/$1"
  {
    echo '#!/usr/bin/env bash'
    echo "printf '%q ' \"\$@\" >>\"$STUBS/$1.calls\"; echo >>\"$STUBS/$1.calls\""
    printf '%s\n' "$2"
  } >"$f"
  chmod +x "$f"
}

finish() {
  echo "$PASSED passed, $FAILED failed"
  [ "$FAILED" -eq 0 ]
  exit $?
}
