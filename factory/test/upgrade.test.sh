#!/usr/bin/env bash
# Tests for factory/bin/upgrade: checks and upgrades scratch installs from a
# scratch copy of this checkout, so the source can gain commits.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$FACTORY_SRC/.." && pwd)

# source_repo: prints the path of a git repo holding a copy of this checkout's
# .claude/ and factory/ (working tree, so uncommitted scripts are included).
source_repo() {
  local d
  d=$(mktemp -d "$TEST_TMP/source.XXXXXX") || return 1
  {
    cp -R "$ROOT/.claude" "$ROOT/factory" "$d/" &&
      rm -rf "$d/factory/settings.json" "$d/.claude/worktrees" &&
      find "$d/factory/jobs" -mindepth 1 ! -name .gitkeep -exec rm -rf {} + &&
      git init -q -b main "$d" && git -C "$d" add -A && git -C "$d" commit -q -m source
  } >/dev/null 2>&1 || return 1
  echo "$d"
}

# target_repo: prints the path of a fresh git repo with one commit and no factory.
target_repo() {
  local d
  d=$(mktemp -d "$TEST_TMP/target.XXXXXX") || return 1
  { git init -q -b main "$d" && echo hi >"$d/README" && git -C "$d" add -A && git -C "$d" commit -q -m init; } >/dev/null 2>&1 || return 1
  echo "$d"
}

# commit_in <repo> <msg>: commits everything in <repo>.
commit_in() { git -C "$1" add -A >/dev/null && git -C "$1" commit -q -m "$2" >/dev/null; }

test_up_to_date() {
  local s t out code
  s=$(source_repo) t=$(target_repo)
  "$s/factory/bin/install" "$t" >/dev/null 2>&1
  out=$("$s/factory/bin/upgrade" "$t")
  code=$?
  assert_eq 0 "$code" "an up-to-date target exits 0"
  assert_contains "$out" "installed: $(git -C "$s" rev-parse HEAD)" "shows the installed version"
  assert_contains "$out" "source:    $(git -C "$s" rev-parse HEAD)" "shows the source version"
  assert_contains "$out" "up to date" "says it is up to date"
  echo mine >"$t/factory/bin/my-script"
  out=$("$s/factory/bin/upgrade" "$t")
  code=$?
  assert_eq 0 "$code" "a file only the target has does not make it stale"
  assert_contains "$out" "extra    factory/bin/my-script" "lists a file only the target has"
}

test_behind() {
  local s t out code before
  s=$(source_repo) t=$(target_repo)
  "$s/factory/bin/install" "$t" >/dev/null 2>&1
  commit_in "$t" "install factory"
  echo "# changed" >>"$s/factory/bin/job-set" && commit_in "$s" "change job-set"
  echo new >"$s/factory/agents/new-role.md" && commit_in "$s" "add a role"
  before=$(git -C "$t" status --porcelain)
  out=$("$s/factory/bin/upgrade" "$t")
  code=$?
  assert_eq 3 "$code" "a target that is behind exits 3"
  assert_contains "$out" "installed: $(git -C "$s" rev-parse HEAD~2)" "shows the installed version"
  assert_contains "$out" "behind:    2 commits" "counts the commits between them"
  assert_contains "$out" "changed  factory/bin/job-set" "lists a changed shipped file"
  assert_contains "$out" "new      factory/agents/new-role.md" "lists a new shipped file"
  assert_eq "" "$(printf '%s\n' "$out" | grep 'factory/bin/install')" "an unchanged shipped file is not listed"
  assert_eq "$before" "$(git -C "$t" status --porcelain)" "the check changes nothing"
}

test_customised_owned_files() {
  local s t out
  s=$(source_repo) t=$(target_repo)
  "$s/factory/bin/install" "$t" >/dev/null 2>&1
  echo custom >"$t/factory/autopilot-policy.md"
  commit_in "$t" "install factory"
  echo '{}' >"$s/factory/models.json" && commit_in "$s" "change the default models"
  out=$("$s/factory/bin/upgrade" "$t")
  assert_contains "$out" "customised factory/autopilot-policy.md" "lists a customised owned file"
  assert_eq "" "$(printf '%s\n' "$out" | grep 'customised factory/models.json')" "an owned file the user never touched is not customised"
  assert_eq custom "$(cat "$t/factory/autopilot-policy.md")" "the check keeps the customised file"
}

test_unversioned() {
  local s t out code
  s=$(source_repo) t=$(target_repo)
  "$s/factory/bin/install" "$t" >/dev/null 2>&1
  rm "$t/factory/VERSION"
  echo "# old" >>"$t/factory/bin/job-set"
  commit_in "$t" "old install"
  out=$("$s/factory/bin/upgrade" "$t")
  code=$?
  assert_eq 3 "$code" "an unversioned target exits 3"
  assert_contains "$out" "installed: unversioned" "reports the target as unversioned"
  assert_contains "$out" "changed  factory/bin/job-set" "shows its drift file by file"
  assert_eq "" "$(printf '%s\n' "$out" | grep '^behind:')" "no commit count without a version"
}

test_apply() {
  local s t out code
  s=$(source_repo) t=$(target_repo)
  "$s/factory/bin/install" "$t" >/dev/null 2>&1
  echo custom >"$t/factory/autopilot-policy.md"
  echo '{"mine":true}' >"$t/factory/models.json"
  commit_in "$t" "install factory"
  echo "# changed" >>"$s/factory/bin/job-set" && commit_in "$s" "change job-set"
  echo "# changed" >>"$s/factory/autopilot-policy.md" && commit_in "$s" "change the policy"
  out=$("$s/factory/bin/upgrade" --apply "$t")
  code=$?
  assert_eq 0 "$code" "--apply exits 0"
  assert_contains "$out" "changed  factory/bin/job-set" "--apply shows what it changes"
  assert_eq "$(cat "$s/factory/bin/job-set")" "$(cat "$t/factory/bin/job-set")" "--apply overwrites shipped files"
  assert_eq custom "$(cat "$t/factory/autopilot-policy.md")" "--apply keeps a customised owned file"
  assert_eq '{"mine":true}' "$(cat "$t/factory/models.json")" "--apply keeps models.json"
  assert_eq "$(git -C "$s" rev-parse HEAD)" "$(cat "$t/factory/VERSION")" "--apply updates the version file"
  out=$("$s/factory/bin/upgrade" "$t")
  assert_eq 0 "$?" "a check after --apply is up to date"
  assert_contains "$out" "customised factory/autopilot-policy.md" "and still lists the customised file"
}

test_usage() {
  local s t
  s=$(source_repo) t=$(target_repo)
  assert_exit 2 "no target is a usage error" -- "$s/factory/bin/upgrade"
  assert_exit 2 "an unknown flag is a usage error" -- "$s/factory/bin/upgrade" --force "$t"
  assert_exit 1 "a non-git target fails" -- "$s/factory/bin/upgrade" "$TEST_TMP"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
