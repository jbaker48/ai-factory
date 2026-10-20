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

# jobj <id> <job json> [<usage line>...]: a job folder with exactly that job.json.
jobj() {
  local id=$1 json=$2
  shift 2
  mkdir -p "$R/factory/jobs/$id"
  echo "$json" >"$R/factory/jobs/$id/job.json"
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
  case $out in *002-b*) _fail "finished jobs get no line" "$out" ;; *) _pass ;; esac
}

test_finished_jobs_no_line() {
  fresh
  job 001-a review "$(ul build 1000000 0 0)"
  job 002-b merged "$(ul build 1000000 0 0)"
  job 003-c dropped "$(ul build 1000000 0 0)"
  out=$(run)
  assert_eq "001-a review: 1.0M in (0% cached), 0k out, 1 runs
trend (last 1 merged): first-pass 1/1, median rounds 0.0, median reworks+respecs 0.0, median tokens 1.0M
quota: no data
claude: tokens only" "$out" "only the unfinished job, then quota and claude"
  fresh
  job 002-b merged "$(ul build 1000000 0 0)"
  assert_eq "trend (last 1 merged): first-pass 1/1, median rounds 0.0, median reworks+respecs 0.0, median tokens 1.0M
quota: no data
claude: tokens only" "$(run)" "all finished: quota and claude lines only"
}

test_trend_line() {
  fresh
  jobj 001-a '{"id":"001-a","stage":"merged","updated":"2026-10-01","round":1,"reworks":0,"respecs":0,"human_decision":null,"tasks":[{"runs":1}]}' "$(ul build 1000000 0 0)"
  jobj 002-b '{"id":"002-b","stage":"merged","updated":"2026-10-02","round":3,"reworks":1,"respecs":0}' "$(ul build 3000000 0 0)"
  jobj 003-c '{"id":"003-c","stage":"merged","updated":"2026-10-03","round":8,"reworks":2,"respecs":1}'
  assert_contains "$(run)" "trend (last 3 merged): first-pass 1/3, median rounds 3.0, median reworks+respecs 1.0, median tokens 2.0M" "trend"
}

test_trend_newest_by_id() {
  fresh
  # Unpadded ids, so a string sort puts 10-x before 2-x. 1-x and 2-x are the
  # oldest and not first-pass, but a later retro re-stamped their updated.
  for i in $(seq 1 12); do
    if [ "$i" -le 2 ]; then
      jobj "$i-x" "{\"stage\":\"merged\",\"updated\":\"2026-12-$(printf '%02d' "$i")\",\"round\":4}"
    else
      jobj "$i-x" "{\"stage\":\"merged\",\"updated\":\"2026-10-$(printf '%02d' "$i")\",\"round\":1}"
    fi
  done
  assert_contains "$(run)" "trend (last 10 merged): first-pass 10/10, median rounds 1.0" "trend window is the 10 highest ids, not the newest updated"
}

test_trend_excludes_retro_tokens() {
  fresh
  jobj 001-a '{"id":"001-a","stage":"merged","round":1}' "$(ul build 1000000 0 0)" "$(ul retro 5000000 0 0 | jq -c '.role = "retro"')"
  jobj 002-b '{"id":"002-b","stage":"merged","round":1}' "$(ul retro 4000000 0 0 | jq -c '.role = "retro"')"
  assert_contains "$(run)" "median tokens 1.0M" "retro rows left out of trend tokens"
}

test_trend_no_usage() {
  fresh
  jobj 001-a '{"id":"001-a","stage":"merged","updated":"2026-10-01","round":1,"reworks":0,"respecs":0}'
  assert_eq "trend (last 1 merged): first-pass 1/1, median rounds 1.0, median reworks+respecs 0.0, median tokens n/a
quota: no data
claude: tokens only" "$(run)" "trend without usage"
}

test_trend_caps_at_ten() {
  fresh
  for i in $(seq 1 12); do
    jobj "$(printf '%03d' "$i")-x" "{\"stage\":\"merged\",\"updated\":\"2026-10-$(printf '%02d' "$i")\",\"round\":1}"
  done
  assert_contains "$(run)" "trend (last 10 merged)" "capped at ten"
}

test_trend_first_pass_blockers() {
  fresh
  jobj 001-a '{"stage":"merged","round":1,"human_decision":"approve"}'
  jobj 002-b '{"stage":"merged","round":1,"tasks":[{"runs":2}]}'
  jobj 003-c '{"stage":"dropped","round":1}'
  assert_contains "$(run)" "trend (last 2 merged): first-pass 0/2" "human decision and task reruns block first-pass"
}

test_no_merged_no_trend() {
  fresh
  job 001-a build "$(ul build 1 0 0)"
  case $(run) in *trend*) _fail "no trend without merged jobs" "$(run)" ;; *) _pass ;; esac
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

test_bad_lines_skipped() {
  fresh
  job 001-a build "$(ul build 1000000 0 0 2026-10-19T09:00:00+00:00 '{"window":"weekly","before":1,"after":7,"resets_at":"soon","plan":"p"}')" '42' '{"ts":"2026-10-19T1'
  job 002-b build "$(ul build 2000000 0 0)"
  out=$(run)
  assert_contains "$out" "001-a build: 1.0M in (0% cached), 0k out, 1 runs" "job with bad lines"
  assert_contains "$out" "002-b build: 2.0M in" "healthy job"
  assert_contains "$out" "quota: codex weekly 7% (resets ?)" "bad resets_at"
}

test_even_median() {
  fresh
  job 001-a build "$(ul build 5000000 0 0)"
  for i in 2 3 4 5; do job "00$i-x" merged "$(ul build $((i == 2 || i == 3 ? 1000000 : 3000000)) 0 0)"; done
  # finished totals 1M,1M,3M,3M: median 2M, so 5M is 2.5x
  assert_contains "$(run)" "001-a build: 5.0M in (0% cached), 0k out, 1 runs, FLAG build 2.5× median" "even median"
}

test_autopilot_line() {
  R=$(mkrepo); cd "$R" || return
  mkdir -p factory/jobs/001-demo
  echo '{"id":"001-demo","bead":"demo-1","stage":"merged"}' >factory/jobs/001-demo/job.json
  { ul build 1500000 0 250000; echo '{"trunc'; } >factory/jobs/001-demo/usage.jsonl
  stub bd 'exit 0' # the drain's claim succeeds
  stub claude 'echo "{\"session_id\":\"sid-1\",\"total_cost_usd\":1.5}"'
  # shellcheck disable=SC2016 # the stub expands these when it runs
  printf '#!/usr/bin/env bash\nn=$(cat "%s/n" 2>/dev/null || echo 0); echo $((n+1)) >"%s/n"; [ "$n" = 0 ] && echo demo-1; exit 0\n' "$TEST_TMP" "$TEST_TMP" >factory/bin/next-bead
  printf '#!/usr/bin/env bash\nexit 0\n' >factory/bin/usage-record
  out=$(factory/bin/autopilot 1 2>&1)
  # shellcheck disable=SC2016 # literal dollar sign
  assert_contains "$out" '[001-demo] demo-1 merged, 1.8M tokens, API-equivalent $1.50, session sid-1' "autopilot line"
  cd - >/dev/null || return
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
