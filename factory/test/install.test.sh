#!/usr/bin/env bash
# Tests for factory/bin/install: it installs this checkout into a scratch repo.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$FACTORY_SRC/.." && pwd)
INSTALL=$ROOT/factory/bin/install

# scratch: prints the path of a fresh git repo with one commit on main and no factory.
scratch() {
  local d
  d=$(mktemp -d "$TEST_TMP/target.XXXXXX") || return 1
  { git init -q -b main "$d" && echo hi >"$d/README" && git -C "$d" add -A && git -C "$d" commit -q -m init; } >/dev/null 2>&1 || return 1
  echo "$d"
}

test_install_passes_done_when() {
  local t f
  t=$(scratch)
  assert_exit 0 "install exits 0" -- "$INSTALL" "$t"
  for f in run-codex run-adversarial job-set autopilot; do
    if [ -x "$t/factory/bin/$f" ]; then _pass; else _fail "factory/bin/$f is executable in the target"; fi
  done
  assert_eq "yes" "$([ -f "$t/.claude/skills/factory/SKILL.md" ] && echo yes)" "skill copied"
  assert_eq "yes" "$([ -f "$t/.claude/agents/factory-agent.md" ] && echo yes)" "agent copied"
  assert_eq "yes" "$([ -f "$t/factory/dashboard.html" ] && [ -f "$t/factory/dashboard/runs.js" ] && echo yes)" "dashboard copied"
  assert_eq "yes" "$([ -f "$t/factory/agents/builder.md" ] && echo yes)" "roles copied"
  assert_eq "" "$([ -e "$t/factory/AGENTS.template.md" ] && echo present)" "template stays in the source"
  mkdir -p "$t/factory/jobs/j1" && echo x >"$t/factory/jobs/j1/job.json"
  assert_eq "factory/jobs/.gitkeep" "$(git -C "$t" status --porcelain -uall | awk '{print $2}' | grep '^factory/jobs/')" "git status shows only jobs/.gitkeep under factory/jobs"
}

test_testing_reference_shipped() {
  local t
  t=$(scratch)
  "$INSTALL" "$t" >/dev/null 2>&1
  assert_eq "yes" "$([ -f "$t/factory/testing.md" ] && echo yes)" "testing reference copied"
}

test_owned_files_kept() {
  local t
  t=$(scratch)
  mkdir -p "$t/factory"
  echo '{"mine":true}' >"$t/factory/models.json"
  "$INSTALL" "$t" >/dev/null 2>&1
  assert_eq '{"mine":true}' "$(cat "$t/factory/models.json")" "an existing models.json is kept"
  assert_eq "$(cat "$ROOT/factory/autopilot-policy.md")" "$(cat "$t/factory/autopilot-policy.md")" "a missing autopilot-policy.md is written"
  assert_eq "yes" "$([ -f "$t/factory/jobs/.gitkeep" ] && echo yes)" "jobs/.gitkeep written"
  echo custom >"$t/factory/autopilot-policy.md"
  echo stale >"$t/factory/bin/job-set"
  "$INSTALL" "$t" >/dev/null 2>&1
  assert_eq custom "$(cat "$t/factory/autopilot-policy.md")" "a re-run keeps the user's policy"
  assert_eq "$(cat "$ROOT/factory/bin/job-set")" "$(cat "$t/factory/bin/job-set")" "a re-run replaces shipped files"
}

test_version_file() {
  local t
  t=$(scratch)
  "$INSTALL" "$t" >/dev/null 2>&1
  assert_eq "$(git -C "$ROOT" rev-parse HEAD)" "$(cat "$t/factory/VERSION")" "VERSION holds the source commit"
}

test_gitignore_once() {
  local t want
  t=$(scratch)
  printf 'node_modules/\n/factory/imports/' >"$t/.gitignore" # no trailing newline
  "$INSTALL" "$t" >/dev/null 2>&1
  "$INSTALL" "$t" >/dev/null 2>&1
  want=$(printf '%s\n' 'node_modules/' '/factory/imports/' '/factory/jobs/*' '!/factory/jobs/.gitkeep' '/factory/autopilot-runs/')
  assert_eq "$want" "$(cat "$t/.gitignore")" "gitignore lines added once, existing lines kept"
}

test_refuses_bad_targets() {
  assert_exit 2 "no target is a usage error" -- "$INSTALL"
  assert_exit 1 "a missing target fails" -- "$INSTALL" "$TEST_TMP/nope"
  mkdir -p "$TEST_TMP/plain"
  assert_exit 1 "a non-git target fails" -- "$INSTALL" "$TEST_TMP/plain"
  assert_contains "$("$INSTALL" "$ROOT" 2>&1)" "target is the source checkout" "the source itself is refused"
}

test_manifest_covers_tracked_files() {
  local f kind path hit missing=""
  while read -r f; do
    hit=""
    while read -r kind path _; do
      case $kind in '' | '#'*) continue ;; esac
      case $path in */) case $f in "$path"*) hit=1 ;; esac ;; *) [ "$f" = "$path" ] && hit=1 ;; esac
    done <"$ROOT/factory/manifest"
    [ -n "$hit" ] || missing="$missing $f"
  done < <(git -C "$ROOT" ls-files .claude factory)
  assert_eq "" "$missing" "every tracked file under .claude/ and factory/ has a manifest entry"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
