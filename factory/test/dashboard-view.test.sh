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
APP_VIEW_HARNESS='const fs = require("fs"), vm = require("vm"); const html = fs.readFileSync(process.env.DASHBOARD_HTML, "utf8"); const view = html.match(/<script id="view">([\s\S]*?)<\/script>/)?.[1]; const app = html.match(/<script>\n([\s\S]*?)<\/script>/)?.[1]; if (!view || !app) throw new Error("missing dashboard scripts"); const context = vm.createContext({detailOpenToggles:new Set(),detailTaskDiffCache:new Map(),detailFileCache:new Map(),detailChanges:{},detailChangesError:null,detailId:"job",detailGeneration:7,taskDiffCalls:[]}); context.testContent = {hidden:true,innerHTML:"",querySelectorAll:() => []}; context.detailToggleContent = () => context.testContent; context.updateHtml = (target, value) => { target.innerHTML = value }; context.loadTaskDiff = (...args) => { context.taskDiffCalls.push([...args, context.testContent.innerHTML.includes("src/a.js")]) }; vm.runInContext(view, context); const extract = (name) => { const start = app.indexOf("function " + name + "("); if (start < 0) throw new Error("missing function " + name); const end = app.indexOf("\nfunction ", start + 1); return app.slice(start, end < 0 ? app.length : end); }; vm.runInContext(["runRole","runTime","runTokenText","timelineFileContent","detailToggleMarkup","detailToggleHtml","renderTaskFile","renderChangesContent","renderRun","renderTimelineNote","findTimelineRun","toggleDetailSection"].map(extract).join("\n"), context); const value = vm.runInContext(process.argv[1], context); process.stdout.write(JSON.stringify(value));'
a() { node -e "$APP_VIEW_HARNESS" "$1"; }

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

test_markdown_code_inside_link_label() {
  assert_eq '"<a href=\"http://a/b\" target=\"_blank\" rel=\"noopener\"><code>code</code> x</a>"' \
    "$(v 'inline("[`code` x](http://a/b)")')" "code spans inside link labels render"
}

test_hash() {
  assert_eq '["001-a",null,null]' "$(v '["#job=001-a","#job=../x","#other"].map(hashJob)')" "hash parsing"
}

test_detail_criteria_has_covered_tasks_and_status_words() {
  assert_eq true "$(v '(() => { const html = criteriaHtml([{n:1,text:"Pass **with evidence**.",tasks:[{id:"t.1",status:"closed"},{id:"t.2",status:"in_progress"},{id:"t.3",status:"blocked"}]}],null); return html.includes("<strong>with evidence</strong>") && html.includes("t.1</span><span class=\"criteria-status closed\">closed</span>") && html.includes("criteria-status running") && html.includes("criteria-status blocked") })()')" "criteria render markdown and covered task statuses"
}

test_detail_criteria_note_uses_div_around_markdown() {
  assert_eq true "$(v '(() => { const html = criteriaHtml(null,"A paragraph."); return html.startsWith("<div class=\"detail-note\"><p>A paragraph.</p></div>") && !html.startsWith("<p class=\"detail-note\"><p>") })()')" "criteria note has valid markdown container markup"
}

test_detail_facts_are_plain_and_separated_by_middots() {
  assert_eq '"<span class=\"detail-fact stage\">review</span><span class=\"detail-separator\" aria-hidden=\"true\">·</span><span class=\"detail-fact\">round 2</span><span class=\"detail-separator\" aria-hidden=\"true\">·</span><span class=\"detail-fact\">4 tasks</span>"' \
    "$(v 'detailFactsHtml([{value:"review",kind:"stage"},{value:"round 2"},{value:"4 tasks"}])')" "header facts are plain text with only stage accented"
}

test_detail_links_use_full_pull_request_label() {
  assert_eq '["Pull request","Retro PR","Factory retro PR"]' \
    "$(v 'detailLinks({pr:"https://example.com/pull/1",retro_pr:"https://example.com/pull/2",retro_factory_pr:"https://example.com/pull/3"}).map(([label])=>label)')" "detail pull request labels are clear"
}

test_detail_change_summary_omits_missing_total() {
  assert_eq true "$(v 'changeSummary({kind:null,files:[],added:0,removed:0}) === null && changeSummary({kind:"landing",files:[{path:"a"},{path:"b"}],added:184,removed:3}) === "2 files, +184 −3"')" "change summary uses whole-job totals and omits missing changes"
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

test_detail_runs_slot_is_empty_for_task_seven() {
  assert_eq true "$(p 'html.includes(`<div id="d-runs" class="detail-runs"></div>`)')" "runs column stays empty until Task 7"
}

test_changes_toggle_renders_on_open_by_run_id_and_refreshes_on_changes_response() {
  assert_eq true "$(p '(() => { const script = html.split("<script>")[1]?.split("</script>")[0] || ""; const toggle = script.slice(script.indexOf("function toggleDetailSection("), script.indexOf("\nasync function loadJobDiff", script.indexOf("function toggleDetailSection("))); const changes = script.slice(script.indexOf("const changesRequest = fetchJson("), script.indexOf("const runsRequest = fetchJson(", script.indexOf("const changesRequest = fetchJson("))); return toggle.includes("findTimelineRun(detailTimeline, button.dataset.runId)") && toggle.includes("renderChangesContent(run)") && changes.includes("renderTimeline(detailTimeline, id, generation)") })()')" "Changes fills on open and re-renders after changes load"
}

test_changes_toggle_populates_open_content() {
  assert_eq '["true",false,true]' "$(a '(() => { detailTimeline=[{kind:"build",runs:[{id:"r1",task:"t1"}]}]; detailChanges={t1:{files:[]}}; const button={dataset:{detailToggle:"r1:changes",toggleKind:"changes",runId:"r1"},attrs:{"aria-expanded":"false"},getAttribute(name){return this.attrs[name]},setAttribute(name,value){this.attrs[name]=value}}; toggleDetailSection(button); return [button.attrs["aria-expanded"],testContent.hidden,testContent.innerHTML.includes("none")] })()')" "opening Changes renders the matching run content"
}

test_reopening_changes_loads_open_task_files_without_cached_diff() {
  assert_eq '[true,[["job","t1","src/a.js","r1:changes:t1:src/a.js",7,"r1",true],["job","t1","src/b.js","r1:changes:t1:src/b.js",7,"r1",true]]]' "$(a '(() => { detailTimeline=[{kind:"build",runs:[{id:"r1",task:"t1"}]}]; detailChanges={t1:{files:[{path:"src/a.js",added:1,removed:0},{path:"src/b.js",added:2,removed:0}]}}; detailOpenToggles.add("r1:changes:t1:src/a.js"); detailOpenToggles.add("r1:changes:t1:src/b.js"); testContent.querySelectorAll = () => [{dataset:{detailToggle:"r1:changes:t1:src/a.js",taskId:"t1",filePath:"src/a.js",runId:"r1"}},{dataset:{detailToggle:"r1:changes:t1:src/b.js",taskId:"t1",filePath:"src/b.js",runId:"r1"}}]; const button={dataset:{detailToggle:"r1:changes",toggleKind:"changes",runId:"r1"},attrs:{"aria-expanded":"false"},getAttribute(name){return this.attrs[name]},setAttribute(name,value){this.attrs[name]=value}}; toggleDetailSection(button); return [testContent.innerHTML.includes("src/a.js"),taskDiffCalls] })()')" "reopening Changes reloads each open task file when its task diff is uncached"
}

test_task_file_toggle_carries_file_path() {
  assert_eq true "$(a 'renderTaskFile({id:"r1",task:"t1"},{path:"src/a.js",added:2,removed:1}).includes(`data-file-path="src/a.js"`)')" "task-file button exposes its path"
}

test_run_toggle_buttons_precede_all_content_blocks() {
  assert_eq true "$(a '(() => { const keys = ["r1:prompt","r1:output","r1:changes"]; for (const key of keys) detailOpenToggles.add(key); detailChanges = {t1:{files:[]}}; const html = renderRun({id:"r1",key:"builder",stage:"build",task:"t1",prompt:null,output:null}); const start = html.indexOf(`<div class="run-toggle-list">`); const end = html.indexOf(`</div>`, start); const row = html.slice(start, end); const contents = [...html.matchAll(/data-detail-content=/g)].map((match) => match.index); return (row.match(/data-toggle-kind=/g) || []).length === 3 && contents.length === 3 && contents.every((index) => index > end) })()')" "run buttons render before their content blocks"
}

test_run_toggle_buttons_use_one_grid_row() {
  assert_eq true "$(p 'html.includes(".run-toggle-list { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0 12px; margin-top: 2px; }")')" "all three run toggles fit one row"
}

test_changes_truncation_message_appears_once_above_file_list() {
  assert_eq true "$(a '(() => { detailChanges={t1:{files:[{path:"src/a.js",added:1,removed:0},{path:"src/b.js",added:1,removed:0}]}}; detailTaskDiffCache.set("t1", {truncated:true,files:[{path:"src/a.js",added:1,removed:0,lines:[{type:"add",text:"+new"}]},{path:"src/b.js",added:1,removed:0,lines:[{type:"add",text:"+other"}]}]}); const html = renderChangesContent({id:"r1",task:"t1"}); return (html.match(/Diff truncated at 2 MB/g) || []).length === 1 && html.indexOf("Diff truncated at 2 MB") < html.indexOf("src/a.js") && (html.match(/class="diff-truncated"/g) || []).length === 1 })()')" "truncation is shown once before task files"
}

test_fully_truncated_file_says_not_shown() {
  assert_eq true "$(a '(() => { detailChanges = {t1:{files:[{path:"src/missing.js",added:1,removed:0}]}}; detailTaskDiffCache.set("t1", {truncated:true,files:[]}); return renderTaskFile({id:"r1",task:"t1"},{path:"src/missing.js",added:1,removed:0}).includes("Not shown: the diff was truncated at 2 MB") })()')" "file omitted at truncation has a specific message"
}

test_note_toggle_key_uses_path_only() {
  assert_eq true "$(a 'renderTimelineNote({path:".runs/note.md"},"moved-group").includes(`data-detail-toggle="note:.runs/note.md:output"`)')" "note toggle key is stable when its group moves"
}

test_detail_desktop_reserves_space_for_panel() {
  assert_eq true "$(p 'html.includes("body.detail-open:not(.detail-expanded) > header.wrap") && html.includes("body.detail-open:not(.detail-expanded) > main.wrap") && html.includes("body.detail-open:not(.detail-expanded) > footer.wrap") && html.includes("width: min(calc(100% - var(--detail-panel-width)), 1440px);") && html.includes("classList.toggle(\u0027detail-open\u0027") && html.includes("classList.toggle(\u0027detail-expanded\u0027, expanded)")')" "desktop panel leaves the board beside it"
}

test_detail_columns_stack_at_899px() {
  assert_eq true "$(p '(() => { const start = html.indexOf("@media (max-width: 899px)"); const end = html.indexOf("@media (max-width: 520px)", start); const media = html.slice(start, end); return media.includes("#detail-panel { width: 100%; min-width: 0; max-width: none; }") && media.includes(".detail-grid { grid-template-columns: minmax(0, 1fr); }") })()')" "detail columns stack at the full-screen breakpoint"
}

test_detail_refresh_preserves_content_and_file_cache() {
  assert_eq true "$(p '(() => { const script = html.split("<script>")[1]?.split("</script>")[0] || ""; const start = script.indexOf("async function requestPanelData("); const end = script.indexOf("\nfunction syncDetail", start); const request = script.slice(start, end); const guard = request.indexOf("if (firstLoad) {"); const blockEnd = request.indexOf("\n  }\n\n  const detailRequest", guard); const initial = request.slice(guard, blockEnd); return request.includes("async function requestPanelData(id, firstLoad)") && guard >= 0 && initial.includes("d-criteria-status") && initial.includes("d-run-count") && initial.includes("Loading…") && !request.includes("detailFileCache = new Map()") && !request.includes("detailFilesLoaded = false") })()')" "only the first panel load shows loading and file cache persists"
}

test_detail_close_focus_falls_back_to_main() {
  assert_eq true "$(p 'html.includes(`<main class="wrap" id="main" tabindex="-1">`) && html.includes("if (!card || document.activeElement !== card) $(\u0027main\u0027)?.focus()")')" "close focus returns to the card or main"
}

test_detail_html_compares_last_written_string() {
  assert_eq true "$(p 'html.includes("detailHtmlWritten.get(element) === value") && html.includes("detailHtmlWritten.set(element, value)")')" "detail HTML skips equal writes using the last string"
}

test_detail_close_is_neutral() {
  assert_eq true "$(p 'html.includes(`<button class="detail-action" id="d-close" type="button">Close</button>`) && !html.includes(`detail-action danger`) && !html.includes(".detail-action.danger")')" "close button uses the neutral action style"
}

test_detail_facts_are_not_boxes() {
  assert_eq true "$(p 'html.includes(".detail-fact { color: var(--ink); overflow-wrap: anywhere; }") && html.includes(".detail-separator { margin: 0 7px; color: var(--muted); }") && !html.includes(".detail-fact { min-height: 32px; display: inline-flex;")')" "header facts read as plain text"
}

test_running_task_dots_use_wait_colour() {
  assert_eq true "$(p 'html.includes(".task-dot.running { background: var(--wait); border-color: var(--wait); }")')" "running task dots use amber wait colour"
}

test_cards_stand_out_from_lanes_in_both_themes() {
  assert_eq true "$(p 'html.includes("--lane: #e3e8ef") && html.includes("--surface: #ffffff") && html.includes("--lane: #1b222c") && html.includes("--surface: #293442")')" "card and lane surfaces differ in light and dark themes"
}

test_fold() {
  local g='[{"kind":"spec"},{"kind":"round","round":1},{"kind":"between","after":1},{"kind":"round","round":2},{"kind":"between","after":2},{"kind":"round","round":3},{"kind":"approve"}]'
  assert_eq '["spec","round","fold","between","round","approve"]' "$(v "foldTimeline($g).map(x=>x.kind)")" "three rounds fold the middle"
  assert_eq '"Rework cycle 1 (round 2)"' "$(v "foldTimeline($g)[2].label")" "singular label"
}

test_fold_eight_rounds_keeps_last_between_visible() {
  local g='[{"kind":"round","round":1},{"kind":"between","after":1},{"kind":"round","round":2},{"kind":"between","after":2},{"kind":"round","round":3},{"kind":"between","after":3},{"kind":"round","round":4},{"kind":"between","after":4},{"kind":"round","round":5},{"kind":"between","after":5},{"kind":"round","round":6},{"kind":"between","after":6},{"kind":"round","round":7},{"kind":"between","after":7},{"kind":"round","round":8}]'
  assert_eq '["round","fold","between","round"]' "$(v "foldTimeline($g).map(x=>x.kind)")" "eight rounds keep the last between visible"
  assert_eq '"Rework cycles 1 to 6 (rounds 2 to 7)"' "$(v "foldTimeline($g)[1].label")" "eight-round fold label"
}

test_fold_four_rounds_without_between_groups() {
  local g='[{"kind":"round","round":1},{"kind":"round","round":2},{"kind":"round","round":3},{"kind":"round","round":4}]'
  assert_eq '["round","fold","round"]' "$(v "foldTimeline($g).map(x=>x.kind)")" "four rounds fold even when gaps are absent"
  assert_eq '"Rework cycles 1 to 2 (rounds 2 to 3)"' "$(v "foldTimeline($g)[1]?.label ?? null")" "four-round label remains stable without gaps"
}

test_parse_diff() {
  local d; d=$(printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n ctx\n+<b>new</b>\n' | jq -Rs .)
  assert_eq '["x",1,0]' "$(v "(p=>[p.path,p.added,p.removed])(parseDiff($d)[0])")" "one file, one added line"
}

test_parse_diff_deletion_uses_old_path_and_escapes_rendered_lines() {
  local d; d=$(printf 'diff --git a/old.txt b/old.txt\n--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-<script>\n' | jq -Rs .)
  assert_eq '["old.txt",0,1]' "$(v "(p=>[p.path,p.added,p.removed])(parseDiff($d)[0])")" "deleted file uses old path"
  assert_eq true "$(v "(() => { const html = diffHtml($d, true); return html.includes('Diff truncated at 2 MB') && html.includes('class=\"diff-line del\">-&lt;script&gt;') && !html.includes('<script>') })()")" "diff lines are escaped and truncation is visible"
}

test_diff_line_spans_have_no_newline_between_lines() {
  assert_eq true "$(v '(() => { const html = diffFilesHtml([{lines:[{type:"add",text:"+first"},{type:"add",text:"+second"}]}]); return html.includes(`+first</span><span class="diff-line add">+second`) && !html.includes(`</span>\n<span class="diff-line`) })()')" "consecutive diff lines have no extra whitespace newline"
}

test_parse_diff_tracks_hunks_before_recognizing_headers() {
  local d; d=$(printf 'diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1,2 @@\n----\n++ x\n' | jq -Rs .)
  assert_eq '["file.txt",1,1,"del"]' "$(v "(p=>[p.path,p.added,p.removed,p.lines.find(x=>x.text==='----').type])(parseDiff($d)[0])")" "removed --- line is content inside the hunk"
  assert_eq '"file.txt"' "$(v "parseDiff($d)[0].path")" "added ++ line does not become a file header"
}

test_parse_diff_falls_back_to_b_path_without_file_headers() {
  local d; d=$(printf 'diff --git "a/old name.txt" "b/new name.txt"\nsimilarity index 100%%\nrename from old name.txt\nrename to new name.txt\n' | jq -Rs .)
  assert_eq '"new name.txt"' "$(v "parseDiff($d)[0].path")" "rename without --- and +++ uses b path"
}

test_parse_diff_binary_and_mode_only_paths_fall_back_to_b() {
  local d; d=$(printf 'diff --git a/image.png b/image.png\nindex 12..34\nBinary files a/image.png and b/image.png differ\ndiff --git a/script.js b/script.js\nold mode 100644\nnew mode 100755\n' | jq -Rs .)
  assert_eq '["image.png","script.js"]' "$(v "parseDiff($d).map(file=>file.path)")" "binary and mode-only changes keep their b paths"
}

test_plan_tasks() {
  assert_eq '"- `1.1` Add guard (covers 1, 2)"' \
    "$(v 'planTasks({tasks:[{key:"1.1",title:"Add guard",covers:[1,2]}]})')" "plan tasks use keys, titles and coverage"
}

test_detail_open_board_uses_two_by_two_lanes_and_panel_width() {
  assert_eq true "$(p '(() => { const start = html.indexOf("@media (min-width: 900px)"); const end = html.indexOf("@media (max-width: 899px)", start); const media = html.slice(start, end); return html.includes("body.detail-open { --detail-panel-width: min(640px, 48vw); }") && media.includes("body.detail-open:not(.detail-expanded) .lanes { grid-template-columns: repeat(2, minmax(0, 1fr));") && html.includes("#detail-panel {") && html.includes("width: min(640px, 48vw); min-width: 0;") })()')" "open detail keeps a readable two by two board"
}

test_invalid_timeline_has_agent_runs_heading() {
  assert_eq true "$(p '(() => { const script = html.split("<script>")[1]?.split("</script>")[0] || ""; return script.includes(`<h2>Agent runs</h2><p class="detail-message error" role="alert">Could not load agent runs: invalid response</p>`) })()')" "invalid timeline has the Agent runs heading"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
