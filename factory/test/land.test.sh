#!/usr/bin/env bash
# Tests for factory/bin/land, pr-land and local-land. Real git; gh is a stub.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export PR_LAND_REGISTER_WAIT=0 PR_LAND_REGISTER_INTERVAL=0 LAND_LOCK_INTERVAL=0.1
URL=https://github.com/o/r/pull/7

# setup [settings-json]: a repo $R with origin $ORIGIN and settings.
setup() {
  R=$(mkrepo)
  ORIGIN=$(git -C "$R" remote get-url origin)
  [ -n "${1:-}" ] && printf '%s' "$1" >"$R/factory/settings.json"
  rm -f "$STUBS"/*.calls
  return 0
}

# mkjob <id> <base-ref>: worktree on factory/<id> from <base-ref> with one commit
# touching <id>.txt, plus factory/jobs/<id>/job.json with reviewed_base = <base-ref>.
mkjob() {
  local id=$1 ref=$2 wt="$TEST_TMP/wt-$1-$RANDOM" rb
  git -C "$R" worktree add -q -b "factory/$id" "$wt" "$ref" >/dev/null 2>&1
  echo "$id" >"$wt/$id.txt"
  git -C "$wt" add -A && git -C "$wt" commit -q -m "job $id"
  rb=$(git -C "$R" rev-parse "$ref")
  mkdir -p "$R/factory/jobs/$id"
  jq -n --arg id "$id" --arg wt "$wt" --arg rb "$rb" \
    '{id: $id, bead: "b-1", feature: "Feature", worktree: $wt, round: 1, reviewed_base: $rb}' \
    >"$R/factory/jobs/$id/job.json"
  WT=$wt JOB="$R/factory/jobs/$id"
}

# origin_commit <file> <content>: pushes a commit to origin main from a clone.
origin_commit() {
  local c
  c=$(mktemp -d "$TEST_TMP/clone.XXXXXX")
  {
    git clone -q "$ORIGIN" "$c" &&
      echo "$2" >"$c/$1" &&
      git -C "$c" add -A &&
      git -C "$c" commit -q -m "upstream $1" &&
      git -C "$c" push -q origin main
  } >/dev/null 2>&1
}

# gh_stub <required-checks-body> [watch-body] [all-checks-body] [list-body]
gh_stub() {
  stub gh "case \"\$*\" in
  'pr list'*) ${4:-:} ;;
  'pr create'*) echo $URL ;;
  *'--required --watch'*) ${2:-echo pass} ;;
  *'--watch'*) ${2:-echo pass} ;;
  *'--required'*) $1 ;;
  'pr checks'*) ${3:-echo pass} ;;
  'pr merge'*) : ;;
  *) echo \"unexpected gh \$*\" >&2; exit 99 ;;
esac"
}

calls() { cat "$STUBS/gh.calls" 2>/dev/null; }
L() { "$R/factory/bin/land" "$JOB"; }
# within <secs> <cmd...>: runs cmd, killed after secs (macOS has no timeout(1)).
within() { perl -e 'alarm shift; exec @ARGV' "$@"; }

test_pr_merges_with_required_checks() {
  setup; mkjob 001-a origin/main; gh_stub 'echo pass'
  out=$(L); rc=$?
  assert_eq 0 "$rc" "pr: merged exits 0"
  assert_eq "$URL" "$(printf '%s\n' "$out" | head -n1)" "pr: url is first stdout line"
  assert_contains "$(calls)" "pr merge $URL --squash" "pr: squash merge called"
  assert_eq "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$R" ls-remote "$ORIGIN" refs/heads/factory/001-a | cut -f1)" "pr: branch pushed"
}

test_pr_no_required_checks_watches_all() {
  setup; mkjob 001-a origin/main
  gh_stub "echo 'no required checks reported on the factory/001-a branch'; exit 1"
  within 5 "$R/factory/bin/land" "$JOB" >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc" "no required checks: exits 0 in time"
  assert_contains "$(calls)" "pr checks $URL --watch" "no required checks: watches all checks"
  assert_contains "$(calls)" "pr merge $URL --squash" "no required checks: merged"
}

test_pr_no_checks_at_all_merges() {
  setup; mkjob 001-a origin/main
  gh_stub "echo 'no checks reported on the factory/001-a branch'; exit 1" '' \
    "echo 'no checks reported on the factory/001-a branch'; exit 1"
  assert_exit 0 "no checks at all: exits 0" -- L
  case $(calls) in *--watch*) _fail "no checks at all: should not watch" ;; *) _pass ;; esac
  assert_contains "$(calls)" "pr merge $URL --squash" "no checks at all: merged"
}

test_pr_reuses_open_pr() {
  setup; mkjob 001-a origin/main; gh_stub 'echo pass' '' '' "echo $URL"
  assert_exit 0 "reuse: exits 0" -- L
  case $(calls) in *"pr create"*) _fail "reuse: must not create a PR" ;; *) _pass ;; esac
}

test_pr_checks_fail() {
  setup; mkjob 001-a origin/main; gh_stub 'echo pass' 'echo boom; exit 1'
  assert_exit 3 "checks fail: exit 3" -- L
  assert_eq yes "$([ -s "$JOB/.runs/checks.log" ] && echo yes)" "checks fail: checks.log written"
  case $(calls) in *"pr merge"*) _fail "checks fail: must not merge" ;; *) _pass ;; esac
}

test_conflict() {
  setup; mkjob 001-a origin/main; gh_stub 'echo pass'
  origin_commit 001-a.txt upstream
  assert_exit 4 "conflict: exit 4" -- L
  assert_eq "" "$(git -C "$R" ls-remote "$ORIGIN" refs/heads/factory/001-a)" "conflict: branch not pushed"
  assert_eq "" "$(calls)" "conflict: gh never called"
}

test_base_moved_clean() {
  setup; mkjob 001-a origin/main; gh_stub 'echo pass'
  origin_commit other.txt upstream
  assert_exit 6 "moved base: exit 6" -- L
  assert_eq "$(git -C "$R" rev-parse origin/main)" "$(git -C "$WT" rev-parse HEAD^2)" "moved base: merge commit's 2nd parent is new origin/main"
  assert_eq "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$R" ls-remote "$ORIGIN" refs/heads/factory/001-a | cut -f1)" "moved base: merge commit pushed"
  case $(calls) in *"pr merge"*) _fail "moved base: must not merge" ;; *) _pass ;; esac
}

test_base_moves_during_ci_wait() {
  setup; mkjob 001-a origin/main
  c="$TEST_TMP/ci-clone"
  gh_stub 'echo pass' "git clone -q $ORIGIN $c >/dev/null 2>&1; echo x >$c/ci.txt; git -C $c add -A; git -C $c commit -q -m ci; git -C $c push -q origin main >/dev/null 2>&1; echo pass"
  assert_exit 6 "moved during CI: exit 6" -- L
  assert_eq "$(git -C "$c" rev-parse HEAD)" "$(git -C "$WT" rev-parse HEAD^2)" "moved during CI: merged the new base"
  case $(calls) in *"pr merge"*) _fail "moved during CI: must not merge" ;; *) _pass ;; esac
}

test_missing_reviewed_base_after_move() {
  setup; mkjob 001-a origin/main; gh_stub 'echo pass'
  jq 'del(.reviewed_base)' "$JOB/job.json" >"$JOB/j" && mv "$JOB/j" "$JOB/job.json"
  origin_commit other.txt upstream
  assert_exit 6 "no reviewed_base, base moved: exit 6" -- L
}

test_local_merges() {
  setup '{"land":"local"}'; mkjob 001-a main
  before=$(git -C "$R" ls-remote "$ORIGIN" | sort)
  assert_exit 0 "local: exit 0" -- L
  assert_eq "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$R" rev-parse main^2)" "local: main merged the job branch"
  assert_eq "$before" "$(git -C "$R" ls-remote "$ORIGIN" | sort)" "local: origin unchanged"
  assert_eq "" "$(calls)" "local: gh never called"
}

test_local_busy_checkout() {
  setup '{"land":"local"}'; mkjob 001-a main
  echo dirty >"$R/README"
  assert_exit 7 "local busy: exit 7" -- L
  git -C "$R" checkout -q README
  git -C "$R" checkout -q -b other
  assert_exit 7 "local not on main: exit 7" -- L
}

test_local_base_moved() {
  setup '{"land":"local"}'; mkjob 001-a main
  echo more >"$R/more.txt"; git -C "$R" add more.txt; git -C "$R" commit -q -m more
  assert_exit 6 "local moved base: exit 6" -- L
  assert_eq "$(git -C "$R" rev-parse main)" "$(git -C "$WT" rev-parse HEAD^2)" "local moved base: worktree merged main"
}

test_local_lock_serialises() {
  setup '{"land":"local"}'
  mkjob 001-a main; j1=$JOB
  mkjob 002-b main; j2=$JOB
  "$R/factory/bin/local-land" "$j1" >/dev/null 2>&1 & p1=$!
  "$R/factory/bin/local-land" "$j2" >/dev/null 2>&1 & p2=$!
  wait "$p1"; r1=$?
  wait "$p2"; r2=$?
  case "$r1 $r2" in
    "0 0" | "0 6" | "6 0") _pass ;;
    *) _fail "lock: both land or one re-reviews" "got $r1 $r2" ;;
  esac
  assert_eq no "$([ -e "$R/factory/.land-lock" ] && echo yes || echo no)" "lock: lock dir removed"
  assert_eq "" "$(git -C "$R" status --porcelain -- . ':!factory/')" "lock: main checkout clean"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
