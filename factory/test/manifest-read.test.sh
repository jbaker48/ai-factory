#!/usr/bin/env bash
# Tests for factory/bin/manifest-read, the one manifest parser install and
# upgrade share.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

S=$(source_repo)
T=$(mktemp -d "$TEST_TMP/target.XXXXXX")
git init -q -b main "$T" && echo hi >"$T/README" && git -C "$T" add -A && git -C "$T" commit -q -m init
M=$S/factory/manifest

# with_manifest <text>: replaces the source's manifest and commits it.
with_manifest() { printf '%s\n' "$1" >"$M"; git -C "$S" commit -qam manifest; }

test_reads_entries_skipping_comments() {
  with_manifest $'# a comment\n\nshipped factory/bin/\n  # indented comment\nowned factory/models.json\nsource factory/test/'
  assert_eq $'shipped factory/bin/\nowned factory/models.json\nsource factory/test/' \
    "$("$S/factory/bin/manifest-read")" "prints each entry, comments and blanks skipped"
  assert_eq "factory/bin/" "$("$S/factory/bin/manifest-read" shipped)" "with a kind, prints only its paths"
}

test_rejects_bad_entries() {
  local bad
  for bad in 'shipped /etc/passwd' 'shipped factory/../x' 'shipped' 'copied factory/bin/'; do
    with_manifest "$bad"
    assert_exit 1 "rejects: $bad" -- "$S/factory/bin/manifest-read"
  done
}

test_install_and_upgrade_share_it() {
  with_manifest 'shipped factory/../escape'
  assert_contains "$("$S/factory/bin/install" "$T" 2>&1)" "bad manifest path: factory/../escape" "install rejects a bad path"
  assert_contains "$("$S/factory/bin/upgrade" "$T" 2>&1)" "bad manifest path: factory/../escape" "upgrade rejects the same path"
  assert_exit 1 "upgrade fails on a bad manifest" -- "$S/factory/bin/upgrade" "$T"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
