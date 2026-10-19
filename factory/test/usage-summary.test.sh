#!/usr/bin/env bash
# Tests for factory/bin/usage-summary.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

US="$FACTORY_SRC/bin/usage-summary"

# fresh: an empty repo-like dir with factory/jobs; sets R.
fresh() { R=$(mktemp -d "$TEST_TMP/s.XXXXXX"); mkdir -p "$R/factory/jobs"; }

# job <id> <stage> [<usage line>...]: a job folder with those usage lines.
job() {
  local id=$1 stage=$2
  shift 2
  mkdir -p "$R/factory/jobs/$id"
  echo "{\"id\":\"$id\",\"stage\":\"$stage\"}" >"$R/factory/jobs/$id/job.json"
  [ $# -gt 0 ] && printf '%s\n' "$@" >"$R/factory/jobs/$id/usage.jsonl"
}

# ul <stage> <input> <cached> <output> [<ts>] [<quota json>]: one usage line.
ul() {
  jq -n -c --arg s "$1" --argjson i "$2" --argjson c "$3" --argjson o "$4" \
    --arg ts "${5:-2026-10-19T10:00:00+00:00}" --argjson q "${6:-null}" \
    '{ts:$ts,role:"builder",provider:"openai",model:"m",effort:"medium",stage:$s,round:1,task:null,
      input:$i,cached:$c,cache_write:0,output:$o,reasoning:0,duration_s:1,exit:0,ended:"x",quota:$q,log:"l"}'
}

run() { (cd "$R" && "$US"); }

test_line_format() {
  fresh
  job 001-a build "$(ul build 1000000 500000 20000)" "$(ul build 500000 250000 10000)"
  out=$(run)
  assert_contains "$out" "001-a build: 1.5M in (50% cached), 30k out, 2 runs" "line format"
}

test_flag_needs_three_finished() {
  fresh
  job 001-a build "$(ul build 5000000 0 0)"
  job 002-b merged "$(ul build 1000000 0 0)"
  job 003-c merged "$(ul build 1000000 0 0)"
  out=$(run)
  case $out in *FLAG*) _fail "no flag with 2 finished" "$out" ;; *) _pass ;; esac
  job 004-d dropped "$(ul build 1000000 0 0)"
  out=$(run)
  assert_contains "$out" "001-a build: 5.0M in (0% cached), 0k out, 1 runs, FLAG build 5.0× median" "flag with 3 finished"
  case $(grep '^002-b' <<<"$out") in *FLAG*) _fail "no flag at 1x" ;; *) _pass ;; esac
}

test_null_tokens_count_as_runs() {
  fresh
  job 001-a build "$(ul build null null null)" "$(ul build 2000000 0 0)"
  assert_contains "$(run)" "001-a build: 2.0M in (0% cached), 0k out, 2 runs" "nulls as zero"
}

test_quota_line_newest() {
  fresh
  job 001-a build \
    "$(ul build 1 0 0 2026-10-19T09:00:00+00:00 '{"window":"weekly","before":10,"after":30,"resets_at":1792874508,"plan":"p"}')" \
    "$(ul build 1 0 0 2026-10-19T11:00:00+00:00 '{"window":"weekly","before":30,"after":42,"resets_at":1792874508,"plan":"p"}')" \
    "$(ul build 1 0 0 2026-10-19T12:00:00+00:00 null)"
  out=$(run)
  assert_contains "$out" "quota: codex weekly 42% (resets $(jq -n -r '1792874508 | strftime("%Y-%m-%d")'))" "newest quota"
  assert_eq "claude: tokens only" "$(tail -n 1 <<<"$out")" "claude line last"
}

test_no_quota_data() {
  fresh
  job 001-a build "$(ul build 1 0 0)"
  out=$(run)
  assert_contains "$out" "quota: no data" "no quota"
  assert_eq "claude: tokens only" "$(tail -n 1 <<<"$out")" "claude line"
}

test_no_usage_files() {
  fresh
  job 001-a build
  assert_eq "quota: no data" "$(run)" "only quota line"
  rm -rf "$R/factory/jobs"
  assert_eq "quota: no data" "$(run)" "no jobs dir"
}

test_autopilot_line() {
  R=$(mkrepo); cd "$R" || return
  mkdir -p factory/jobs/001-demo
  echo '{"id":"001-demo","bead":"demo-1","stage":"merged"}' >factory/jobs/001-demo/job.json
  ul build 1500000 0 250000 >factory/jobs/001-demo/usage.jsonl
  stub claude 'echo "{\"session_id\":\"sid-1\",\"total_cost_usd\":1.5}"'
  # shellcheck disable=SC2016 # the stub expands these when it runs
  printf '#!/usr/bin/env bash\nn=$(cat "%s/n" 2>/dev/null || echo 0); echo $((n+1)) >"%s/n"; [ "$n" = 0 ] && echo demo-1; exit 0\n' "$TEST_TMP" "$TEST_TMP" >factory/bin/next-bead
  printf '#!/usr/bin/env bash\nexit 0\n' >factory/bin/usage-record
  out=$(factory/bin/autopilot 1 2>&1)
  # shellcheck disable=SC2016 # literal dollar sign
  assert_contains "$out" 'autopilot: 001-demo (demo-1) merged, 1.8M tokens, API-equivalent $1.50, session sid-1' "autopilot line"
  cd - >/dev/null || return
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
