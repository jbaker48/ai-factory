#!/usr/bin/env bash
# Tests for factory/bin/task-description, against a fixture plan.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TD="$FACTORY_SRC/bin/task-description"
PLAN="$LIB_DIR/fixtures/plan/plan.json"

test_seam_reaches_description() {
  local want out
  want='Scope: src/cart.js. Done when: a 10% code takes 10% off. Verify: npm test.

Seam: checkout(cart, code) in src/cart.js
Catches: a wrong total for a valid or expired code
Misses: how the total is rendered on the page

Covers acceptance criteria: 1, 2. Plan key: T1.'
  out=$("$TD" "$PLAN" T1)
  assert_eq "$want" "$out" "T1 description carries its seam"
}

test_no_seam_no_seam_lines() {
  local want out
  want='Run the validation commands from AGENTS.md and check every acceptance criterion in spec.md. Write build.md.

Covers acceptance criteria: 1, 2. Plan key: T2.'
  out=$("$TD" "$PLAN" T2)
  assert_eq "$want" "$out" "final task has no seam lines"
}

test_unknown_key() {
  assert_exit 1 "unknown key exits 1" -- "$TD" "$PLAN" T9
}

test_usage() {
  assert_exit 2 "missing key exits 2" -- "$TD" "$PLAN"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
