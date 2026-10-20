#!/usr/bin/env bash
# Tests the pure view helpers in factory/dashboard.html.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$FACTORY_SRC/.." && pwd)
DASHBOARD_HTML="$ROOT/factory/dashboard.html"
export DASHBOARD_HTML

VIEW_HARNESS='const fs = require("fs"), vm = require("vm"); const html = fs.readFileSync(process.env.DASHBOARD_HTML, "utf8"); const match = html.match(/<script id="view">([\s\S]*?)<\/script>/); if (!match) throw new Error("missing <script id=\"view\">"); const context = vm.createContext({}); vm.runInContext(match[1], context); const value = vm.runInContext(process.argv[1], context); process.stdout.write(JSON.stringify(value));'
v() { node -e "$VIEW_HARNESS" "$1"; }
PAGE_HARNESS='const fs = require("fs"); const html = fs.readFileSync(process.env.DASHBOARD_HTML, "utf8"); process.stdout.write(JSON.stringify(Function("html", "return (" + process.argv[1] + ")")(html)));'
p() { node -e "$PAGE_HARNESS" "$1"; }

BOARD_FIXTURE='({models:{"spec-writer":{model:"opus"},planner:{model:"sonnet"},builder:{model:"gpt-6-luna"}},jobs:[{id:"001-a",bead:"demo-1",feature:"Write the spec",stage:"spec",usage:[]},{id:"002-b",feature:"Build the task",stage:"build",tasks:[{id:"t1",status:"in_progress"},{id:"t2",status:"open"}],usage:[{input:7,output:8}],usage_derived:true},{id:"003-c",feature:"Review changes",stage:"review",round:3,reviews:{security:"PASS",code:"CHANGES"},usage:[]},{id:"004-d",feature:"Plan blocked",stage:"needs-human",situation:"plan-blocked",round:1,reviews:{}},{id:"005-e",feature:"Finished",stage:"merged",tasks:[],pr:"https://example.com/pull/5",usage:[]}]})'
board() { v "renderBoard($BOARD_FIXTURE)"; }

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

test_board_running_lane() {
  assert_contains "$(board)" "Running" "board has running lane"
}

test_board_deciding_lane() {
  assert_contains "$(board)" "Deciding" "board has deciding lane"
}

test_board_needs_you_lane() {
  assert_contains "$(board)" "Needs you" "board has needs-you lane"
}

test_board_done_lane() {
  assert_contains "$(board)" "Done" "board has done lane"
}

test_board_spec_stage_copy() {
  assert_contains "$(board)" "writing spec.md" "spec card says what it is writing"
}

test_board_build_stage_copy() {
  assert_contains "$(board)" "task 1 of 2" "build card shows task progress"
  assert_contains "$(board)" "gpt-6-luna" "build card shows builder model"
}

test_board_review_stage_copy() {
  assert_contains "$(board)" "round 3" "review card shows round"
  assert_contains "$(board)" "pending" "review card shows pending reviewers"
}

test_board_needs_situation_and_hint() {
  assert_contains "$(board)" "Needs you: Plan blocked" "needs-you card translates situation"
  assert_contains "$(board)" "/factory review 004-d" "needs-you card has review hint"
}

test_board_token_text() {
  assert_contains "$(board)" "tokens not recorded" "card without usage says tokens are not recorded"
  assert_contains "$(board)" "15 tokens" "card totals input and output tokens"
}

test_board_codex_provenance_requires_tokens() {
  assert_eq false "$(v 'renderBoard({jobs:[{id:"empty-usage",feature:"No usage",stage:"merged",usage:[],usage_derived:true}]}).includes("from Codex logs")')" "no Codex provenance without a token total"
}

test_board_pr_link_is_inside_visible_shell_but_outside_button() {
  assert_eq true "$(v '(() => { const q = String.fromCharCode(34); const html = renderBoard({jobs:[{id:"pr",feature:"Pull request",stage:"merged",tasks:[{id:"t1"}],pr:"https://example.com/pull/5"}]}); const shell = html.split("<div class=" + q + "card-shell" + q + ">")[1]; const button = shell?.indexOf("<button"); const close = shell?.indexOf("</button>"); const link = shell?.indexOf("<a class=" + q + "pr-link" + q); const end = shell?.indexOf("</div>"); return !!shell && button >= 0 && close > button && link > close && end > link })()')" "PR link is below its card button inside the shell"
  assert_eq true "$(p 'html.includes(".card-shell { display: grid; min-width: 0; border: 1px solid var(--line); background: var(--surface); border-radius: 4px;")')" "card shell supplies the visible card treatment"
}

test_board_card_button_has_inline_children_and_accessible_description() {
  assert_eq true "$(v '(() => { const html = renderBoard({jobs:[{id:"access",feature:"Accessible card",stage:"build",tasks:[{id:"t1",status:"running"}],usage:[{input:1,output:1}]},{id:"review",feature:"Review card",stage:"review",round:1,reviews:{}}]}); const blockTags = ["<div", "<section", "<p", "<h1", "<h2", "<h3", "<ul", "<ol", "<table"]; const cards = html.split("<button class=" + String.fromCharCode(34) + "job-card").slice(1).map((part) => { const end = part.indexOf("</button>"); const openEnd = part.indexOf(">"); const button = part.slice(0, end); const body = part.slice(openEnd + 1, end); return end > 0 && !blockTags.some((tag) => body.includes(tag)) && button.includes("aria-label=") && button.includes("aria-describedby=") }); return cards.length === 2 && cards.every(Boolean) })()')" "card buttons use inline elements and a short name plus description"
}

test_board_card_accessible_name_has_job_id_and_feature() {
  assert_eq true "$(v 'renderBoard({jobs:[{id:"access-7",feature:"Readable feature",stage:"spec"}]}).includes(`aria-label="access-7: Readable feature"`)')" "card name combines job id and feature"
}

test_board_done_empty_tasks_says_not_recorded() {
  assert_eq true "$(v '(() => { const html = renderBoard({jobs:[{id:"merged",feature:"Finished",stage:"merged",tasks:[]}]}); return html.includes("tasks not recorded") && !html.includes("Merged</span><span>none") })()')" "done card with no tasks says tasks not recorded"
}

test_board_one_change_is_singular() {
  assert_eq true "$(v 'reviewRoundLine({stage:"merged",round:1,reviews:{code:"CHANGES"}}).includes("Round 1: 1 change")')" "one review change is singular"
}

test_board_situation_does_not_read_prototype_properties() {
  assert_eq true "$(v '(() => { const line = decisionLine({stage:"needs-human",situation:"constructor"}); return line.includes("Needs you") && !line.includes("[native code]") && !line.includes("function") })()')" "situation lookup ignores inherited keys"
}

test_markdown_link_is_extracted_before_emphasis() {
  assert_eq true "$(v 'inline("[a](http://x/*b*)").includes(`<a href="http://x/*b*" target="_blank" rel="noopener">a</a>`)')" "emphasis markers in a link URL stay intact"
}

test_markdown_rejects_executable_link_inputs() {
  assert_eq true "$(v '(() => { const quote = String.fromCharCode(34); const unsafe = inline("[x](javascript:alert(1))"); const quoted = inline("[x](http://a" + quote + " onmouseover=x)"); const tags = quoted.match(/<[^>]+>/g) || []; return !unsafe.includes("<a ") && !tags.some((tag) => tag.includes("onmouseover=")) })()')" "unsafe link schemes and quoted attributes do not create executable markup"
}

test_board_hostile_card_fields_are_escaped() {
  assert_eq true "$(v '(() => { const quote = String.fromCharCode(34); const html = renderBoard({jobs:[{id:"job" + quote + "><img src=x onerror=alert(1)>",bead:"<svg onload=alert(1)> " + quote + "quoted" + quote,feature:"<img src=x onerror=alert(1)> " + quote + "feature" + quote,stage:"merged",tasks:[]}]}); return !html.includes("<img") && !html.includes("<svg") && html.includes("&quot;") && html.includes("&lt;img") && html.includes("&lt;svg") })()')" "hostile id, bead and feature stay escaped"
}

test_theme_toggle_is_light_dark_only() {
  assert_eq true "$(p '(() => { const script = html.split("<script>")[1]?.split("</script>")[0] || ""; return script.includes("const THEMES = [\u0027light\u0027, \u0027dark\u0027]") && script.includes(": \u0027light\u0027") && script.includes("Dark theme") && script.includes("Light theme") && !script.includes("\u0027auto\u0027") })()')" "theme defaults to light and toggles between light and dark"
}

test_spend_summary_has_visible_disclosure_and_tap_height() {
  assert_eq true "$(p 'html.includes("#spend summary { min-height: 44px; display: list-item;")')" "spend summary keeps its marker and 44px target"
}

test_page_does_not_hide_horizontal_overflow() {
  assert_eq false "$(p 'html.includes("overflow-x: hidden")')" "page does not hide horizontal overflow"
}

test_running_task_dots_use_wait_colour() {
  assert_eq true "$(p 'html.includes(".task-dot.running { background: var(--wait); border-color: var(--wait); }")')" "running task dots use amber wait colour"
}

test_cards_stand_out_from_lanes_in_both_themes() {
  assert_eq true "$(p 'html.includes("--lane: #e3e8ef") && html.includes("--surface: #ffffff") && html.includes("--lane: #1b222c") && html.includes("--surface: #293442")')" "card and lane surfaces differ in light and dark themes"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
