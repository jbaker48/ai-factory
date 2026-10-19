#!/usr/bin/env bash
# Smoke test for factory/bin/bd-stress: a tiny 2x2 run against a scratch repo.
# Skips (passes) when bd is not on PATH. The full stress run is not part of this suite.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v bd >/dev/null || ! command -v jq >/dev/null; then
  echo "skip: bd or jq not on PATH"
  finish
fi

test_smoke() {
  out=$("$FACTORY_SRC/bin/bd-stress" 2 2 2>&1)
  assert_eq "bd-stress: 2×2 ok" "$out" "2 writers x 2 rounds pass"
}

test_bad_usage() {
  "$FACTORY_SRC/bin/bd-stress" abc >/dev/null 2>&1
  assert_eq 2 "$?" "non-numeric arg exits 2"
}

test_zero_args() {
  "$FACTORY_SRC/bin/bd-stress" 0 2 >/dev/null 2>&1
  assert_eq 2 "$?" "0 writers exits 2"
  "$FACTORY_SRC/bin/bd-stress" 2 0 >/dev/null 2>&1
  assert_eq 2 "$?" "0 rounds exits 2"
}

test_smoke
test_zero_args
test_bad_usage
finish
