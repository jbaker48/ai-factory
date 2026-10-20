#!/usr/bin/env bash
# Tests for factory/bin/run-codex.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# setup <jsonl-body> <exit-code>: a repo whose codex stub prints the body and exits.
setup() {
  R=$(mkrepo)
  JOB="$R/job"; mkdir -p "$JOB"
  printf '%s' "$1" >"$TEST_TMP/codex.out"
  stub codex "cat '$TEST_TMP/codex.out'; exit ${2:-0}"
  rm -f "$STUBS/codex.calls"
}
RC() { "$R/factory/bin/run-codex" builder "$JOB" "$R" "do it"; }

NORMAL='{"type":"thread.started"}
{"type":"turn.started"}
{"type":"turn.completed"}
'
TRUNC='{"type":"thread.started"}
{"type":"item.started"}
{"type":"item.comp'

test_mcp_disabled() {
  setup "$NORMAL"
  mkdir -p "$TEST_TMP/ch"
  printf '[mcp_servers.repomix]\ncommand = "x"\n[mcp_servers."a.b"]\ncommand = "y"\n' >"$TEST_TMP/ch/config.toml"
  CODEX_HOME="$TEST_TMP/ch" RC >/dev/null
  calls=$(cat "$STUBS/codex.calls")
  assert_contains "$calls" "mcp_servers.repomix.enabled=false" "bare server disabled"
  case $calls in *a.b*) _fail "non-bare name skipped" "$calls" ;; *) _pass ;; esac
}

test_no_config() {
  setup "$NORMAL"
  mkdir -p "$TEST_TMP/empty"
  out=$(CODEX_HOME="$TEST_TMP/empty" RC)
  case $(cat "$STUBS/codex.calls") in *mcp_servers*) _fail "no mcp flags without config" ;; *) _pass ;; esac
  assert_contains "$out" "ended turn.completed" "run still works"
}

test_ended_normal() {
  setup "$NORMAL"
  out=$(RC)
  assert_contains "$out" "exit 0, ended turn.completed. Last message:" "normal run"
  assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line on success"
}

test_ended_truncated() {
  setup "$TRUNC" 1
  out=$(RC); rc=$?
  assert_contains "$out" "exit 1, ended item.started." "truncated last line ignored"
  assert_eq 1 "$rc" "exit code passes through"
}

test_ended_none() {
  setup "" 0
  assert_contains "$(RC)" "ended none." "empty log"
}

test_malformed_config() {
  setup "$NORMAL"
  mkdir -p "$TEST_TMP/bad"
  printf '[mcp_servers\n=== nope' >"$TEST_TMP/bad/config.toml"
  out=$(CODEX_HOME="$TEST_TMP/bad" RC 2>"$TEST_TMP/err")
  case $(cat "$STUBS/codex.calls") in *mcp_servers*) _fail "no mcp flags on bad config" ;; *) _pass ;; esac
  assert_contains "$out" "ended turn.completed" "run proceeds"
  assert_contains "$(cat "$TEST_TMP/err")" "could not read $TEST_TMP/bad/config.toml; MCP servers left on" "warning"
  case $(cat "$TEST_TMP/err") in *Traceback*) _fail "no traceback" ;; *) _pass ;; esac
}

test_extra_dirs() {
  setup "$NORMAL"
  "$R/factory/bin/run-codex" builder "$JOB" "$R" "do it" "$TEST_TMP/extra" >/dev/null
  assert_contains "$(cat "$STUBS/codex.calls")" "--add-dir $TEST_TMP/extra" "extra dir writable"
}

test_browser_session() {
  setup "$NORMAL"
  # shellcheck disable=SC2016
  stub agent-browser 'echo "$AGENT_BROWSER_SOCKET_DIR" >>"$STUBS/ab.dirs"'
  stub codex "echo \"\$AGENT_BROWSER_SOCKET_DIR\" >'$TEST_TMP/codex.dir'; cat '$TEST_TMP/codex.out'"
  jq '.["reviewer-ux"] = {provider: "openai", model: "m", network: true, browser: true}' \
    "$R/factory/models.json" >"$TEST_TMP/m" && mv "$TEST_TMP/m" "$R/factory/models.json"
  "$R/factory/bin/run-codex" reviewer-ux "$JOB" "$R" "review" >/dev/null
  local calls dir
  calls=$(cat "$STUBS/agent-browser.calls")
  assert_contains "$calls" "--session $(basename "$JOB")-ux open about:blank" "opens the session"
  assert_contains "$calls" "--session $(basename "$JOB")-ux close" "closes the session"
  dir=$(cat "$TEST_TMP/codex.dir")
  assert_contains "$dir" "/tmp/fab." "codex sees the socket dir"
  if [ -e "$dir" ]; then _fail "socket dir removed"; else _pass; fi
}

test_no_browser_by_default() {
  setup "$NORMAL"
  stub agent-browser 'exit 0'; rm -f "$STUBS/agent-browser.calls"
  RC >/dev/null
  if [ -e "$STUBS/agent-browser.calls" ]; then _fail "no browser for builder"; else _pass; fi
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
