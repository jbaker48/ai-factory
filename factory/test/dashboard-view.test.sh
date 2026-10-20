#!/usr/bin/env bash
# Tests the pure view helpers in factory/dashboard.html.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$FACTORY_SRC/.." && pwd)
DASHBOARD_HTML="$ROOT/factory/dashboard.html"
export DASHBOARD_HTML

VIEW_HARNESS='const fs = require("fs"), vm = require("vm"); const html = fs.readFileSync(process.env.DASHBOARD_HTML, "utf8"); const match = html.match(/<script id="view">([\s\S]*?)<\/script>/); if (!match) throw new Error("missing <script id=\"view\">"); const context = vm.createContext({}); vm.runInContext(match[1], context); const value = vm.runInContext(process.argv[1], context); process.stdout.write(JSON.stringify(value));'
v() { node -e "$VIEW_HARNESS" "$1"; }

test_lanes() {
  assert_eq '["running","running","deciding","needs","needs","done"]' \
    "$(v '["spec","review","autopilot","needs-human","resubmitted","dropped"].map(laneOf)')" "stage to lane"
}

test_escape() {
  assert_eq false "$(v 'markdown("<img src=x onerror=alert(1)> `<b>` **&**").includes("<img")')" "markdown escapes html"
  assert_eq false "$(v 'inline("<script>").includes("<script")')" "inline escapes html"
}

test_tokens() {
  assert_eq null "$(v 'jobTokens({usage: []})')" "no records is null, not 0"
  assert_eq 15 "$(v 'jobTokens({usage: [{input: 10, output: 5}]})')" "sums records"
}

test_done_order() {
  assert_eq '["b","a"]' "$(v 'doneOrder([{id:"a",updated:"2026-10-19T01:00:00Z"},{id:"b",updated:"2026-10-20T01:00:00Z"}]).map(j=>j.id)')" "newest first"
}

test_view_is_document_free() {
  assert_eq true "$(v 'typeof document === "undefined" && typeof window === "undefined"')" "view has no DOM globals"
}

test_empty_tokens_are_not_zero() {
  assert_eq true "$(v 'renderSpend([]).summary.includes("tokens not recorded") && !renderSpend([]).summary.includes("0 tokens")')" "empty spend has no zero token total"
  assert_eq true "$(v 'usageMarkdown([]).includes("tokens not recorded") && !usageMarkdown([]).includes("0 tokens")')" "empty usage has no zero token total"
}

test_review_uses_current_round() {
  assert_eq true "$(v '(() => { const result = reviewData({stage:"review",round:3,reviews:{},past:[{security:"PASS"}]}); return result.number === 3 && result.verdicts.security === undefined && reviewBoxes(result.verdicts).includes("pending") })()')" "review cards show pending current round"
}

test_board_cards() {
  assert_eq true "$(v '(() => { const html = renderBoard({models:{"spec-writer":{model:"opus"},planner:{model:"sonnet"},builder:{model:"gpt-6-luna"}},jobs:[{id:"001-a",bead:"demo-1",feature:"Write the spec",stage:"spec",usage:[]},{id:"002-b",feature:"Build the task",stage:"build",tasks:[{id:"t1",status:"in_progress"},{id:"t2",status:"open"}],usage:[{input:7,output:8}],usage_derived:true},{id:"003-c",feature:"Review changes",stage:"review",round:3,reviews:{security:"PASS",code:"CHANGES"},usage:[]},{id:"004-d",feature:"Plan blocked",stage:"needs-human",situation:"plan-blocked",round:1,reviews:{}},{id:"005-e",feature:"Finished",stage:"merged",tasks:[],pr:"https://example.com/pull/5",usage:[]}]}); return html.includes("Running") && html.includes("Deciding") && html.includes("Needs you") && html.includes("Done") && html.includes("writing spec.md") && html.includes("task 1 of 2") && html.includes("gpt-6-luna") && html.includes("round 3") && html.includes("pending") && html.includes("Needs you: Plan blocked") && html.includes("/factory review 004-d") && html.includes("tokens not recorded") && html.includes("15 tokens") && html.includes("from Codex logs") && html.includes("https://example.com/pull/5") && html.includes("none") })()')" "board cards show lane data"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
