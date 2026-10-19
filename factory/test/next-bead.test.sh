#!/usr/bin/env bash
# Tests for factory/bin/next-bead.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# a: P2 old; b: P1 new; c: P3 labelled lane:x
QUEUE='[
{"id":"a","priority":2,"created_at":"2026-01-01T00:00:00Z","labels":["factory","queued"]},
{"id":"b","priority":1,"created_at":"2026-03-01T00:00:00Z","labels":["factory","queued"]},
{"id":"c","priority":3,"created_at":"2026-02-01T00:00:00Z","labels":["factory","queued","lane:x"]}
]'

setup() { # [settings-json] [queue-json]
  R=$(mkrepo)
  rm -f "$R/factory/settings.json"
  [ -n "${1:-}" ] && printf '%s' "$1" >"$R/factory/settings.json"
  stub bd "cat <<'JSON'
${2:-$QUEUE}
JSON"
  rm -f "$STUBS/bd.calls"
  unset FACTORY_PRIORITY_LABELS FACTORY_EXCLUDE_BEADS
}
N() { "$R/factory/bin/next-bead"; }

test_plain_priority() {
  setup
  assert_eq b "$(N)" "no labels: highest priority wins"
}

test_label_first() {
  setup '{"priority_labels":["lane:x"]}'
  assert_eq c "$(N)" "labelled bead beats higher priority"
}

test_env_override() {
  setup '{"priority_labels":["lane:x"]}'
  assert_eq b "$(FACTORY_PRIORITY_LABELS=nope N)" "env var overrides setting"
}

test_empty_queue() {
  setup '' '[]'
  assert_eq "" "$(N)" "empty queue prints nothing"
  assert_exit 0 "empty queue exits 0" -- N
}

test_exclude() {
  setup
  assert_eq a "$(FACTORY_EXCLUDE_BEADS=b N)" "excluded bead skipped"
  assert_eq c "$(FACTORY_EXCLUDE_BEADS='b  a' N)" "several excluded"
  assert_eq "" "$(FACTORY_EXCLUDE_BEADS='a b c' N)" "all excluded prints nothing"
  assert_eq b "$(FACTORY_EXCLUDE_BEADS='' N)" "empty list skips nothing"
}

test_never_claims() {
  setup
  N >/dev/null
  assert_eq 1 "$(wc -l <"$STUBS/bd.calls" | tr -d ' ')" "only one bd call"
  assert_contains "$(cat "$STUBS/bd.calls")" "ready" "bd ready used"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
