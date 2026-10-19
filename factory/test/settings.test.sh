#!/usr/bin/env bash
# Tests for factory/bin/settings.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Runs the settings script of a fresh repo copy, with an optional settings.json body.
setup() { # [json]
  R=$(mkrepo)
  rm -f "$R/factory/settings.json"
  [ $# -gt 0 ] && printf '%s' "$1" >"$R/factory/settings.json"
  return 0
}
S() { "$R/factory/bin/settings" "$@"; }

test_defaults_without_file() {
  setup
  assert_eq pr "$(S land)" "land defaults to pr"
  assert_eq 1 "$(S jobs 1)" "default arg used for missing key"
  assert_eq "" "$(S priority_labels)" "priority_labels empty"
  assert_eq origin/main "$(S base)" "base is origin/main"
}

test_local_mode_base() {
  setup '{"land":"local"}'
  assert_eq main "$(S base)" "base is main in local mode"
}

test_array_joined() {
  setup '{"priority_labels":["lane:a","lane:b"]}'
  assert_eq "lane:a lane:b" "$(S priority_labels)" "arrays space-joined"
}

test_malformed_file() {
  setup '{'
  local err rc
  err=$(S land 2>&1 >/dev/null); rc=$?
  assert_eq 1 "$rc" "malformed file exits 1"
  assert_contains "$err" "settings:" "stderr names settings"
}

test_env_override_and_scalars() {
  setup
  printf '{"jobs":3,"flag":false}' >"$TEST_TMP/alt.json"
  assert_eq 3 "$(FACTORY_SETTINGS=$TEST_TMP/alt.json S jobs 1)" "FACTORY_SETTINGS overrides"
  assert_eq false "$(FACTORY_SETTINGS=$TEST_TMP/alt.json S flag x)" "false is a value, not missing"
}

test_stub_logs_one_line_per_call() {
  stub fake 'true'
  fake -n "a
b" --flag
  fake second
  assert_eq 2 "$(wc -l <"$STUBS/fake.calls" | tr -d ' ')" "multi-line arg logs one line per call"
}

test_mkrepo_origin() {
  setup
  assert_eq main "$(git -C "$R" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')" "origin HEAD is main"
  assert_eq origin/main "$(git -C "$R" rev-parse --abbrev-ref "main@{upstream}")" "main tracks origin/main"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
