#!/usr/bin/env bash
# Tests for factory/bin/role-prompt.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R=$(mkrepo)
RP() { "$R/factory/bin/role-prompt" "$@"; }

test_codex_prompt_inlines_preamble_and_role() {
  assert_eq "$(cat "$R/factory/role-preamble.md")"$'\n\n'"$(cat "$R/factory/agents/builder.md")"$'\n\n\n---\n\ndo it' \
    "$(RP builder "do it")" "openai prompt is preamble, role file, separator, prompt"
}

test_claude_prompt_starts_with_preamble() {
  local p
  p=$(RP reviewer-code "Job folder: x. Review round 2.")
  assert_eq "$(cat "$R/factory/role-preamble.md")"$'\n\n'"Role: factory/agents/reviewer-code.md"$'\n\n---\n\nJob folder: x. Review round 2.' \
    "$p" "anthropic prompt is preamble, the Role line, separator, prompt"
  assert_contains "$(head -n 1 <<<"$p")" "# Every factory role" "Claude prompt starts with the preamble"
}

test_claude_role_line_follows_agent_field() {
  jq '.["builder-escalation"].provider = "anthropic"' "$R/factory/models.json" >"$TEST_TMP/m.json"
  cp "$TEST_TMP/m.json" "$R/factory/models.json"
  assert_contains "$(RP builder-escalation "Build.")" $'\nRole: factory/agents/builder.md\n' "Role line names the entry's agent"
}

test_errors() {
  assert_exit 2 "unknown key" -- "$R/factory/bin/role-prompt" nope "x"
  assert_exit 2 "missing argument" -- "$R/factory/bin/role-prompt" builder
  assert_exit 2 "codex-plugin role has no prompt" -- "$R/factory/bin/role-prompt" reviewer-adversarial "x"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
