#!/usr/bin/env bash
# Tests for factory/bin/models.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

setup() { R=$(mkrepo); }
M() { "$R/factory/bin/models" "$@"; }

test_shipped_models_is_mixed() {
  setup
  assert_eq mixed "$(M)" "shipped models.json is the mixed preset"
}

test_switch_and_back() {
  setup
  assert_eq "models: mixed -> claude" "$(M claude)" "switch to claude"
  assert_eq claude "$(M)" "claude active"
  assert_eq "" "$(jq -r '[.[] | select(.provider != "anthropic")] | .[]' "$R/factory/models.json")" "claude preset is all anthropic"
  M mixed >/dev/null
  assert_eq mixed "$(M)" "back to mixed"
}

test_openai_preset() {
  setup
  M openai >/dev/null
  assert_eq openai "$(M)" "openai active"
  assert_eq "" "$(jq -r '[.[] | select(.provider != "openai")] | .[]' "$R/factory/models.json")" "openai preset is all openai"
  assert_eq "true true" "$(jq -r '[.["reviewer-ux"].browser, .["reviewer-ui"].browser] | join(" ")' "$R/factory/models.json")" "browser roles flagged"
}

test_lean_preset() {
  setup
  M lean >/dev/null
  assert_eq lean "$(M)" "lean active"
  assert_eq "high high sonnet sonnet" "$(jq -r '[.builder.effort, .autopilot.effort, .importer.model, .briefer.model] | join(" ")' "$R/factory/models.json")" "lean lowers effort and moves writers to sonnet"
}

test_custom_needs_force() {
  setup
  jq '.builder.model = "x"' "$R/factory/models.json" >"$TEST_TMP/m" && mv "$TEST_TMP/m" "$R/factory/models.json"
  assert_eq custom "$(M)" "edited models.json is custom"
  assert_exit 1 "refuses to replace custom" -- M claude
  assert_eq x "$(jq -r .builder.model "$R/factory/models.json")" "custom kept"
  assert_exit 0 "--force replaces custom" -- M claude --force
  assert_eq claude "$(M)" "claude after force"
}

test_unknown_preset() {
  setup
  assert_exit 1 "unknown preset" -- M nope
  assert_exit 2 "bad flag" -- M claude --nope
}

test_presets_cover_same_roles() {
  local a b
  a=$(jq -c 'keys' "$FACTORY_SRC/presets/mixed.json")
  for p in claude openai lean; do
    b=$(jq -c 'keys' "$FACTORY_SRC/presets/$p.json")
    assert_eq "$a" "$b" "$p preset names the same roles as mixed"
  done
  if [ -f "$FACTORY_SRC/agents/reviewer-adversarial.md" ]; then _pass; else _fail "adversarial role file exists"; fi
}

test_builder_tiers() {
  setup
  local p
  for p in mixed lean claude openai; do
    assert_eq "builder builder" "$(jq -r '[."builder-light".agent, ."builder-standard".agent] | join(" ")' "$FACTORY_SRC/presets/$p.json")" "$p tiers use the builder role file"
  done
  assert_eq "medium high" "$(jq -r '[."builder-light".effort, ."builder-standard".effort] | join(" ")' "$FACTORY_SRC/presets/mixed.json")" "mixed tier efforts"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
