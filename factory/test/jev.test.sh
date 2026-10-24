#!/usr/bin/env bash
# Tests for factory/bin/jev.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# respond <n> <code> <time> <body>: the fake curl's answer to its n-th call.
respond() { printf '%s %s\n%s' "$2" "$3" "$4" >"$TEST_TMP/curl.$1"; }
ON='{"jev":{"send":"summary"}}'
setup() { # [settings-json]
  local settings=${1:-$ON}
  R=$(mkrepo); rm -f "$TEST_TMP"/curl.* "$TEST_TMP"/req.* "$TEST_TMP"/hdr.* "$TEST_TMP"/max.* "$STUBS/curl.calls"
  printf '%s' "$settings" >"$R/factory/settings.json"
  printf '{"tone":{"type":"choice","criteria":{"a":"A","b":{"what":"B","not_for":"x"}},"instructions":{"question":"q","about":"s","judge_by":"j"}}}' >"$TEST_TMP/q.json"
  printf 'Task: rename foo.\n' >"$TEST_TMP/s.txt"
  export JEV_KEY=sk-test-123456789
  # shellcheck disable=SC2016
  stub curl '
n=$(( $(cat "$TEST_TMP/curl.n" 2>/dev/null || echo 0) + 1 )); echo $n >"$TEST_TMP/curl.n"
while [ $# -gt 0 ]; do case $1 in
  -o) out=$2; shift ;; -H) case $2 in @*) cp "${2#@}" "$TEST_TMP/hdr.$n" ;; esac; shift ;;
  --data-binary) cp "${2#@}" "$TEST_TMP/req.$n"; shift ;; --max-time) echo "$2" >"$TEST_TMP/max.$n"; shift ;;
esac; shift; done
r="$TEST_TMP/curl.$n"; [ -f "$r" ] || r="$TEST_TMP/curl.1"
tail -n +2 "$r" >"$out"; head -n 1 "$r" | tr -d "\n"
case $(head -c 3 "$r") in 000) exit 7 ;; esac; exit 0'
  rm -f "$TEST_TMP/curl.n"
}
J() { "$R/factory/bin/jev" "$TEST_TMP/q.json" "$TEST_TMP/s.txt"; }
OK='{"model":"jev-2","answers":{"tone":{"type":"choice","choice":"b","confidence":0.7,"probabilities":{"a":0.2,"b":0.8}}},"usage":{"input_tokens":120,"output_tokens":3}}'
ncalls() { cat "$TEST_TMP/curl.n" 2>/dev/null || echo 0; }

test_ok() {
  setup; respond 1 200 0.2 "$OK"
  out=$(J 2>"$TEST_TMP/err"); rc=$?
  assert_eq 0 "$rc" "ok exit"
  assert_eq b "$(jq -r .answers.tone.choice <<<"$out")" "choice"
  assert_eq 0.8 "$(jq -r .answers.tone.p <<<"$out")" "p"
  assert_eq jev-2 "$(jq -r .model <<<"$out")" "response model"
  assert_eq 120 "$(jq -r .input_tokens <<<"$out")" "input tokens"
  assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line"
  assert_eq jev-latest "$(jq -r .model "$TEST_TMP/req.1")" "request model"
  assert_eq true "$(jq '.state == "Task: rename foo.\n"' "$TEST_TMP/req.1")" "request state"
  assert_eq true "$(jq -n --slurpfile r "$TEST_TMP/req.1" --slurpfile q "$TEST_TMP/q.json" '$r[0].questions == $q[0]')" "request questions"
  assert_contains "$(cat "$TEST_TMP/hdr.1")" "Authorization: Bearer sk-test-123456789" "auth header"
  case $(cat "$STUBS/curl.calls") in *sk-test*) _fail "key leaked into argv" ;; *) _pass ;; esac
}

test_off() {
  setup '{}'
  J >/dev/null 2>&1; rc=$?
  assert_eq 3 "$rc" "off exit"
  if [ -e "$STUBS/curl.calls" ]; then _fail "no curl when off"; else _pass; fi
}

test_no_key() {
  setup; unset JEV_KEY
  J >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc" "no key exit"
  if [ -e "$STUBS/curl.calls" ]; then _fail "no curl without key"; else _pass; fi
}

test_retry_once_on_429() {
  setup; respond 1 429 0.1 ''; respond 2 200 0.1 "$OK"
  J >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc" "exit after retry"
  assert_eq 2 "$(ncalls)" "two calls"
}

test_retry_on_dropped_connection() {
  setup; respond 1 000 0.1 ''; respond 2 200 0.1 "$OK"
  J >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc" "exit after retry"
}

test_no_retry_past_deadline() {
  setup; respond 1 503 1.4 ''
  err=$(J 2>&1 >/dev/null); rc=$?
  assert_eq 1 "$rc" "exit"
  assert_eq "jev: HTTP 503" "$err" "stderr"
  assert_eq 1 "$(ncalls)" "one call"
  assert_eq 1 "$(awk -v m="$(cat "$TEST_TMP/max.1")" 'BEGIN{print (m <= 1.5)}')" "first max-time"
}

test_second_try_gets_time_left() {
  setup; respond 1 429 0.5 ''; respond 2 200 0.1 "$OK"
  J >/dev/null 2>&1
  assert_eq 1 "$(awk -v m="$(cat "$TEST_TMP/max.2" 2>/dev/null || echo 0)" 'BEGIN{print (m <= 0.7 && m > 0)}')" "second max-time"
}

test_error_body_not_logged() {
  setup; respond 1 500 0.1 '{"secret":"leak"}'; respond 2 500 0.1 '{"secret":"leak"}'
  err=$(J 2>&1 >/dev/null); rc=$?
  assert_eq 1 "$rc" "exit"
  case $err in *leak*) _fail "body leaked" "$err" ;; *) _pass ;; esac
}

test_bad_choice() {
  setup; respond 1 200 0.1 '{"model":"m","answers":{"tone":{"type":"choice","choice":"zzz"}}}'
  err=$(J 2>&1 >/dev/null); rc=$?
  assert_eq 1 "$rc" "exit"
  assert_eq "jev: no usable answer for tone" "$err" "stderr"
}

test_missing_question() {
  setup; respond 1 200 0.1 '{"answers":{}}'
  err=$(J 2>&1 >/dev/null); rc=$?
  assert_eq 1 "$rc" "exit"
  assert_eq "jev: no usable answer for tone" "$err" "stderr"
}

test_no_probabilities() {
  setup; respond 1 200 0.1 '{"model":"m","answers":{"tone":{"type":"choice","choice":"a"}}}'
  out=$(J 2>/dev/null)
  assert_eq 0 "$(jq -r .answers.tone.p <<<"$out")" "p defaults to 0, so the floor holds"
}

test_redacts_state() {
  setup; respond 1 200 0.1 "$OK"
  printf 'k sk-proj-abcdefghijklmnop g ghp_abcdefghijklmnopqrstuvwxyz0123 a AKIAABCDEFGHIJKLMNOP h Bearer abc.def.ghi e me@example.com u https://bob:hunter2@host/x t token=abcd1234efgh5678 path src/api/key-handler.ts disk-usage-monitoring-service risk-assessment-report-x the password field is required end\n' >"$TEST_TMP/s.txt"
  printf 'j eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4 x xoxb-1234567890-abcdefghij G AIzaSyA1234567890abcdefghijklmnopqrstuv q "api_key": "abcd1234efgh5678" p1 password=hunter2 p2 password: '"'"'abcd1234'"'"' pem -----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAzzzz\n-----END RSA PRIVATE KEY----- tail\n' >>"$TEST_TMP/s.txt"
  out=$(J 2>/dev/null)
  for s in "$(jq -r .state "$TEST_TMP/req.1")" "$(jq -r .state <<<"$out")"; do
    for secret in sk-proj-abc ghp_abc AKIAABC abc.def.ghi me@example hunter2 abcd1234efgh eyJhbGci SflKxw xoxb-1234 AIzaSyA1 MIIEowIB abcd1234 BEGIN; do
      case $s in *"$secret"*) _fail "not redacted: $secret" "$s" ;; *) _pass ;; esac
    done
    assert_contains "$s" "[redacted]" "marker"
    assert_contains "$s" "src/api/key-handler.ts disk-usage-monitoring-service risk-assessment-report-x the password field is required end" "plain words and slugs survive"
  done
}

test_state_capped() {
  setup; respond 1 200 0.1 "$OK"
  head -c 20000 /dev/zero | tr '\0' 'x' >"$TEST_TMP/s.txt"
  J >/dev/null 2>&1
  assert_eq 1 "$(jq '(.state | length) <= 12000 | if . then 1 else 0 end' "$TEST_TMP/req.1")" "state capped"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
