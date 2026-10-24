#!/usr/bin/env bash
# Tests for factory/bin/decisions: prints the current value of each /factory
# setup decision from a scratch install's files.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

D() { "$R/factory/bin/decisions"; }
line() { printf '%s\n' "$OUT" | grep "^$1: " | head -n 1 | sed "s/^$1: //"; }

test_fresh_install_shows_defaults() {
  R=$(mkrepo)
  OUT=$(D)
  assert_eq "8 Always PARK rules" "$(line policy)" "policy counts the Always PARK rules"
  assert_eq "mixed" "$(line preset)" "preset is the shipped mixed"
  assert_eq "not written; values from settings.example.json" "$(line settings)" "settings not yet written"
  assert_eq "pr" "$(line land)" "land defaults to pr"
  assert_eq "(none)" "$(line priority_labels)" "no priority labels"
  assert_eq "1" "$(line jobs)" "jobs defaults to 1"
  assert_eq "(none)" "$(line factory_source)" "no factory source"
  assert_eq "metadata" "$(line jev.send)" "Jev sends metadata by default"
  assert_eq "committed and pushed" "$(line commit)" "mkrepo's install is committed and pushed"
}

test_rerun_shows_recorded_answers() {
  R=$(mkrepo)
  printf '%s' '{"land":"local","priority_labels":["p0","urgent"],"jobs":3,"factory_source":"/src/ai-factory","jev":{"send":"summary"}}' >"$R/factory/settings.json"
  "$R/factory/bin/models" claude >/dev/null
  printf '%s\n' '- touches the billing ledger.' >>"$R/factory/autopilot-policy.md"
  git -C "$R" add -A && git -C "$R" commit -q -m answers
  OUT=$(D)
  assert_eq "8 Always PARK rules" "$(line policy)" "rules outside Always PARK aren't counted"
  assert_eq "claude" "$(line preset)" "preset follows models.json"
  assert_eq "written" "$(line settings)" "settings written"
  assert_eq "local" "$(line land)" "land from settings.json"
  assert_eq "p0 urgent" "$(line priority_labels)" "labels space-joined"
  assert_eq "3" "$(line jobs)" "jobs from settings.json"
  assert_eq "/src/ai-factory" "$(line factory_source)" "factory source from settings.json"
  assert_eq "summary" "$(line jev.send)" "Jev send mode from settings.json"
  assert_eq "committed" "$(line commit)" "local mode needs no push"
}

test_policy_rule_added_and_custom_models() {
  R=$(mkrepo)
  awk '{print} /^## Always PARK/ {getline; print; getline; print; getline; print; print "- touches the billing ledger;"}' \
    "$R/factory/autopilot-policy.md" >"$TEST_TMP/p" && mv "$TEST_TMP/p" "$R/factory/autopilot-policy.md"
  jq '.builder.effort = "max"' "$R/factory/models.json" >"$TEST_TMP/m" && mv "$TEST_TMP/m" "$R/factory/models.json"
  OUT=$(D)
  assert_eq "9 Always PARK rules" "$(line policy)" "an added Always PARK rule counts"
  assert_eq "custom" "$(line preset)" "hand-edited models.json is custom"
  assert_eq "uncommitted" "$(line commit)" "changed factory files are uncommitted"
}

test_committed_not_pushed() {
  R=$(mkrepo)
  printf '%s' '{"land":"pr"}' >"$R/factory/settings.json"
  git -C "$R" add -A && git -C "$R" commit -q -m settings
  OUT=$(D)
  assert_eq "committed, not pushed" "$(line commit)" "pr mode: commit not on origin/main"
  git -C "$R" push -q origin main 2>/dev/null
  OUT=$(D)
  assert_eq "committed and pushed" "$(line commit)" "pr mode: pushed"
}

# The install commit is on the branch checked out, whatever it is called, and
# jobs branch from the base (origin/main in pr mode), so that is the check.
test_commit_checked_on_current_branch() {
  R=$(mkrepo)
  git -C "$R" checkout -q -b setup-factory
  printf '%s' '{"land":"pr"}' >"$R/factory/settings.json"
  git -C "$R" add -A && git -C "$R" commit -q -m settings
  OUT=$(D)
  assert_eq "committed, not pushed" "$(line commit)" "a commit on another branch is not on the base, though main is"
  git -C "$R" push -q origin setup-factory:main 2>/dev/null && git -C "$R" fetch -q origin
  git -C "$R" branch -q -D main
  OUT=$(D)
  assert_eq "committed and pushed" "$(line commit)" "pushed to the base with no local main branch"
}

test_reads_another_repo_and_rejects_bad_settings() {
  local other
  R=$(mkrepo)
  other=$(mkrepo)
  printf '%s' '{"land":"local"}' >"$other/factory/settings.json"
  OUT=$("$R/factory/bin/decisions" "$other")
  assert_eq "local" "$(line land)" "reads the repo it is given"
  printf '{' >"$R/factory/settings.json"
  assert_exit 1 "malformed settings exits 1" -- "$R/factory/bin/decisions"
  assert_exit 2 "two args is usage" -- "$R/factory/bin/decisions" a b
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
