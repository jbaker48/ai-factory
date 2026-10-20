#!/usr/bin/env bash
# Tests for factory/bin/prompt-record.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

setup() {
  R=$(mkrepo)
  J=$(mktemp -d "$TEST_TMP/job.XXXXXX")
  mkdir -p "$J"
}

test_records_role_and_prompt() {
  setup
  local path base first last
  path=$("$R/factory/bin/prompt-record" "$J" reviewer-code "Job folder: x. Review round 2.")
  base=${path##*/}
  assert_contains "$path" "$J/.runs/" "prints prompt path in the job"
  if [[ "$base" =~ ^[0-9]{8}-[0-9]{6}-reviewer-code\.prompt\.md$ ]]; then _pass; else _fail "prompt path has run-codex stamp" "$base"; fi
  first=$(head -n 1 "$R/factory/agents/reviewer-code.md")
  assert_eq "$first" "$(head -n 1 "$path")" "prompt starts with the role file"
  last=$(tail -n 3 "$path")
  assert_eq $'---\n\nJob folder: x. Review round 2.' "$last" "prompt ends with the separator and prompt"
}

test_builder_escalation_uses_builder_role() {
  setup
  local path first
  path=$("$R/factory/bin/prompt-record" "$J" builder-escalation "Build this task.")
  first=$(head -n 1 "$R/factory/agents/builder.md")
  assert_eq "$first" "$(head -n 1 "$path")" "builder-escalation uses agents/builder.md"
}

test_invalid_key_and_arguments() {
  setup
  assert_exit 2 "unknown role key" -- "$R/factory/bin/prompt-record" "$J" unknown-role "prompt"
  assert_exit 2 "missing argument" -- "$R/factory/bin/prompt-record" "$J" reviewer-code
}

test_missing_role_file() {
  setup
  jq '. + {"role-without-file": {"agent": "missing-role-file"}}' \
    "$R/factory/models.json" >"$TEST_TMP/models.json"
  mv "$TEST_TMP/models.json" "$R/factory/models.json"
  assert_exit 2 "missing role file" -- "$R/factory/bin/prompt-record" "$J" role-without-file "prompt"
}

test_write_failure() {
  setup
  : >"$J/.runs"
  assert_exit 1 "cannot create runs directory" -- "$R/factory/bin/prompt-record" "$J" reviewer-code "prompt"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
