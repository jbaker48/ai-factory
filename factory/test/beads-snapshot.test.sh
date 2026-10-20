#!/usr/bin/env bash
# Tests for factory/bin/beads-snapshot, with a stubbed bd.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SNAP="$FACTORY_SRC/bin/beads-snapshot"

# A bd stub: bead app-1 has children app-1.1 (closed), app-1.2 (open), app-1.3 (in_progress).
stub_bd() {
  # shellcheck disable=SC2016
  stub bd '
args="$*"
case $args in
  "--readonly show app-1") echo "BEAD app-1 body" ;;
  "--readonly show app-1 --json --brief-deps") echo "[{\"id\":\"app-1\",\"dependencies\":[{\"id\":\"app-0\"}]}]" ;;
  "--readonly show app-0") echo "DEP app-0 full description" ;;
  "--readonly show app-1.2") echo "TASK app-1.2 full description" ;;
  "--readonly show app-1.3") echo "TASK app-1.3 full description" ;;
  "--readonly show app-1.1") echo "TASK app-1.1 SHOULD NOT APPEAR" ;;
  "--readonly children app-1 --json") echo "[{\"id\":\"app-1.1\",\"status\":\"closed\"},{\"id\":\"app-1.2\",\"status\":\"open\"},{\"id\":\"app-1.3\",\"status\":\"in_progress\"}]" ;;
  "--readonly children app-1") echo "CHILDREN LIST"; echo "app-1.1 closed"; echo "app-1.2 open"; echo "app-1.3 in_progress" ;;
  *) echo "unexpected: $args" >&2; exit 9 ;;
esac'
}

mkjob() {
  local d
  d=$(mktemp -d "$TEST_TMP/job.XXXXXX")
  echo '{"bead":"app-1"}' >"$d/job.json"
  echo "$d"
}

test_writes_sections() {
  stub_bd
  local d f
  d=$(mkjob)
  "$SNAP" "$d" >/dev/null
  f=$(cat "$d/beads.md")
  assert_contains "$f" "## Bead" "has Bead heading"
  assert_contains "$f" "BEAD app-1 body" "has bead show output"
  assert_contains "$f" "## Dependencies" "has Dependencies heading"
  assert_contains "$f" "### app-0" "dependency section"
  assert_contains "$f" "DEP app-0 full description" "dependency description"
  assert_contains "$f" "## Children" "has Children heading"
  assert_contains "$f" "CHILDREN LIST" "has children output"
  assert_contains "$f" "### app-1.2" "open child section"
  assert_contains "$f" "TASK app-1.2 full description" "open child description"
  assert_contains "$f" "TASK app-1.3 full description" "in-progress child description"
  case $f in *"SHOULD NOT APPEAR"*) _fail "closed child must not get a section" ;; *) _pass ;; esac
}

test_counts() {
  stub_bd
  local d out
  d=$(mkjob)
  out=$("$SNAP" "$d")
  assert_eq "beads.md: 3 children, 2 open" "$out" "stdout summary"
}

test_bd_failure() {
  stub bd 'echo "boom" >&2; exit 1'
  local d
  d=$(mkjob)
  assert_exit 1 "bd failure exits 1" -- "$SNAP" "$d"
  assert_contains "$(cat "$d/beads.md")" "bd failed" "file records failure"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
