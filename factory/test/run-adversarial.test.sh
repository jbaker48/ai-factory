#!/usr/bin/env bash
# Tests for factory/bin/run-adversarial prompt recording.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_saves_focus_prompt_before_companion() {
  local R JOB COMPANION SPEC_LINE prompt content rc
  R=$(mkrepo)
  JOB="$TEST_TMP/job"
  mkdir -p "$JOB"
  SPEC_LINE="Acceptance criteria: the adversarial run retains its focus prompt."
  printf '%s\nSecond line.\n' "$SPEC_LINE" >"$JOB/spec.md"
  COMPANION="$TEST_TMP/companion.mjs"
  cat >"$COMPANION" <<'JS'
import fs from 'node:fs'
import path from 'node:path'

const runs = path.join(process.env.PROMPT_JOB, '.runs')
const prompts = fs.readdirSync(runs).filter(name => name.endsWith('-reviewer-adversarial.prompt.md'))
if (prompts.length === 0) {
  console.error('prompt was not saved before companion started')
  process.exit(10)
}
console.log(JSON.stringify({threadId:null,result:{verdict:'approve',summary:'ok',findings:[],next_steps:[]}}))
JS
  PROMPT_JOB="$JOB" CODEX_COMPANION="$COMPANION" \
    "$R/factory/bin/run-adversarial" "$JOB" "$R" 1 >"$TEST_TMP/out" 2>"$TEST_TMP/err"
  rc=$?
  assert_eq 0 "$rc" "adversarial run succeeds with structured companion output"
  prompt=$(find "$JOB/.runs" -type f -name '*-reviewer-adversarial.prompt.md' -print | head -n 1)
  if [ -f "$prompt" ]; then content=$(cat "$prompt"); _pass; else _fail "adversarial prompt exists"; content=""; fi
  assert_contains "$content" "$SPEC_LINE" "saved adversarial prompt contains the spec's first line"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
