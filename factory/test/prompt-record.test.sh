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
  local out path base
  out=$("$R/factory/bin/prompt-record" "$J" reviewer-code "Job folder: x. Review round 2.")
  path=$(find "$J/.runs" -type f -name '*.prompt.md' | head -n 1)
  base=${path##*/}
  if [[ "$base" =~ ^[0-9]{8}-[0-9]{6}-reviewer-code\.prompt\.md$ ]]; then _pass; else _fail "prompt path has run-codex stamp" "$base"; fi
  assert_eq "$(cat "$R/factory/role-preamble.md")"$'\n\n'"Role: factory/agents/reviewer-code.md"$'\n\n---\n\nJob folder: x. Review round 2.' \
    "$out" "prints the Claude prompt: preamble, Role line, then the prompt"
  assert_eq "$out" "$(cat "$path")" "records exactly the prompt it prints"
  assert_contains "$(head -n 1 <<<"$out")" "# Every factory role" "the prompt sent to factory-agent starts with the preamble"
}

test_builder_escalation_uses_builder_role() {
  setup
  local out
  out=$("$R/factory/bin/prompt-record" "$J" builder-escalation "Build this task.")
  assert_contains "$out" "$(head -n 1 "$R/factory/agents/builder.md")" "builder-escalation uses agents/builder.md"
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
