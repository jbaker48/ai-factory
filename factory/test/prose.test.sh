#!/usr/bin/env bash
# Checks on the prose the orchestrator and roles read (SKILL.md, role files, template).
# shellcheck source=/dev/null
# shellcheck disable=SC2016 # backticks in the needles are literal Markdown
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$FACTORY_SRC/.." && pwd)
SKILL_DIR="$ROOT/.claude/skills/factory"

# skill_text: SKILL.md and the subcommand files it points at, for checks that
# don't care which file a rule lives in.
skill_text() { cat "$SKILL_DIR"/*.md; }

test_no_literal_main_diffs() {
  local hits
  hits=$(cd "$ROOT" && grep -nE '(main\.\.|main\.\.\.|merge-tree --write-tree (origin/)?main|--base main)' factory/agents/*.md factory/bin/* .claude/skills/factory/*.md)
  assert_eq "" "$hits" "no role file or script diffs against a literal main"
}

test_prompt_has_base() {
  assert_contains "$(cat "$ROOT/.claude/skills/factory/SKILL.md")" 'Base: <base>.' "Prompts section passes the base"
}

test_agents_rule() {
  local t
  t=$(tr '\n' ' ' <"$ROOT/factory/AGENTS.template.md" | tr -s ' ' | sed 's/Never commit/never commit/')
  assert_contains "$t" 'never commit or push to main directly' "AGENTS template main rule"
  assert_contains "$t" "In local land mode the factory's Merge step is the only thing that commits to main." "AGENTS template local-mode exception"
}

test_roles_skip_bd() {
  local hits
  hits=$(cd "$ROOT" && grep -lE 'bd --readonly|`bd (show|children|list)' factory/agents/*.md)
  assert_eq "" "$hits" "every role can run on Codex, so none calls bd"
}

test_claude_roles_read_preamble() {
  local t
  t=$(tr '\n' ' ' <"$ROOT/.claude/agents/factory-agent.md" | tr -s ' ')
  assert_contains "$t" 'Read `factory/role-preamble.md`' "factory-agent reads the shared preamble"
  assert_contains "$t" 'then the role file' "factory-agent reads the preamble before the role file"
}

# The worktree and Beads-snapshot text lives in factory/role-preamble.md only.
test_roles_share_one_preamble() {
  local needle hits
  for needle in 'Your shell may start anywhere' 'Beads is not available to you' 'not available to you' "orchestrator's snapshot" 'taken just before you started'; do
    assert_contains "$(tr '\n' ' ' <"$ROOT/factory/role-preamble.md" | tr -s ' ')" "$needle" "preamble says: $needle"
    hits=$(cd "$ROOT" && for f in factory/agents/*.md; do tr '\n' ' ' <"$f" | tr -s ' ' | grep -qF "$needle" && echo "$f"; done)
    assert_eq "" "$hits" "no role file repeats: $needle"
  done
}

test_dashboard_reads_usage() {
  grep -q "usage.jsonl" "$ROOT/factory/dashboard.html"
  assert_eq "0" "$?" "dashboard reads usage.jsonl"
}

test_dashboard_retro() {
  local h; h=$(cat "$ROOT/factory/dashboard.html")
  assert_contains "$h" 'retro_pr' "dashboard reads retro_pr"
  assert_contains "$h" 'retro_factory_pr' "dashboard reads retro_factory_pr"
  assert_contains "$h" "'retro.md'" "dashboard ranks retro.md"
}

test_briefer_role() {
  local f="$ROOT/factory/agents/briefer.md" t
  t=$(cat "$f" 2>/dev/null)
  assert_contains "$t" '## Situation' "briefer brief has Situation"
  assert_contains "$t" '## Decisions' "briefer brief has Decisions"
  assert_contains "$t" '## Out of scope' "briefer brief has Out of scope"
  assert_contains "$t" 'Brief k.' "briefer names the Brief task"
  assert_contains "$t" 'Write decision k.' "briefer names the Write decision task"
  assert_contains "$t" 'APPROVE only' "briefer limits APPROVE"
  assert_eq "opus" "$(jq -r '.briefer.model // empty' "$ROOT/factory/models.json")" "models.json has briefer on opus"
}

# section <file> <heading>: prints the lines of the "## <heading>" section, up to the next "## ".
section() {
  awk -v h="## $2" '$0 == h || index($0, h " ") == 1 {on = 1; print; next} on && /^## / {exit} on' "$1"
}

test_review_command() {
  local f="$ROOT/.claude/skills/factory/SKILL.md" t s
  t=$(skill_text)
  assert_contains "$(head -n 1 "$SKILL_DIR/review.md")" '## /factory review' "review.md has /factory review"
  assert_contains "$(sed -n 3p "$f")" '/factory review' "description lists /factory review"
  assert_contains "$t" 'human_decision' "SKILL.md mentions human_decision"
  assert_contains "$t" 'resubmitted' "SKILL.md mentions resubmitted"
  assert_contains "$t" '`dropped`' "SKILL.md mentions dropped"
  assert_contains "$t" '.resume-claim' "SKILL.md mentions .resume-claim"
  assert_contains "$t" 'NEEDS-OWNER' "SKILL.md handles the briefer's NEEDS-OWNER"
  assert_contains "$t" 'factory/bin/autopilot --watch' "review offers a watching drain"
  assert_contains "$(grep -m 1 '^- `stage` is one of' -A 2 "$f")" '`dropped`' "job.json stages list dropped"
  assert_contains "$(grep -m 1 '^- `stage` is one of' -A 2 "$f")" '`resubmitted`' "job.json stages list resubmitted"
  for c in approve rework; do
    s=$(section "$f" "/factory $c")
    assert_contains "$s" 'resubmit' "/factory $c resubmits"
    case $s in *'Run **Merge**'* | *'Go to **Build**'*) _fail "/factory $c no longer runs the job" "$s" ;; *) _pass ;; esac
  done
}

test_roles_read_owner_decisions() {
  local r
  for r in approver autopilot builder spec-writer planner; do
    assert_contains "$(cat "$ROOT/factory/agents/$r.md")" 'human-*.md' "$r reads human-*.md"
  done
  assert_contains "$(tr '\n' ' ' <"$ROOT/factory/agents/autopilot.md" | tr -s ' ')" 'may not RESPEC against' "autopilot can't respec against the owner"
  assert_contains "$(cat "$ROOT/factory/autopilot-policy.md")" 'human-*.md' "policy: owner decisions bind"
  assert_contains "$(cat "$ROOT/README.md")" '/factory review' "README lists /factory review"
}

test_briefer_decision_file() {
  local t
  t=$(cat "$ROOT/factory/agents/briefer.md")
  assert_contains "$t" '## Owner answers' "briefer decision has Owner answers"
  assert_contains "$t" '## Beads filed' "briefer decision has Beads filed"
  assert_contains "$t" 'NEEDS-OWNER' "briefer can ask the owner again"
  assert_contains "$(tr '\n' ' ' <"$ROOT/factory/agents/briefer.md" | tr -s ' ')" 'except the `NEEDS-OWNER:` line above' "briefer Finish allows NEEDS-OWNER"
  assert_contains "$(tr '\n' ' ' <"$ROOT/factory/agents/briefer.md" | tr -s ' ')" 'the escalation or merge block this settles' "briefer APPROVE covers merge blocks"
}

test_review_fixes() {
  local f="$ROOT/.claude/skills/factory/SKILL.md" t s
  t=$(skill_text | tr '\n' ' ' | tr -s ' ')
  assert_contains "$t" '.runs/human-<j>.abandoned.md' "unresubmitted human files are moved out of the glob"
  assert_contains "$t" 'Claimed for you by autopilot' "drain-claimed sessions skip the claim"
  assert_contains "$t" 'rmdir <job folder>/.resume-claim' "stale claims can be cleared"
  assert_contains "$t" "if its stage isn't \`needs-human\`" "review of one job checks its stage"
  assert_contains "$t" '.round_base // 0' "round_base read with a default"
  assert_contains "$t" 'N - round_base < MAX_ROUNDS' "rounds counted from round_base"
  assert_contains "$t" 'N - round_base = MAX_ROUNDS' "last round counted from round_base"
  assert_contains "$t" '`round_base` set to `round`' "resubmit sets round_base"
  assert_contains "$t" 'For REWORK and RESPEC, increment `reworks` or `respecs` and set `round_base` to `round`' "autopilot rework/respec sets round_base"
  assert_contains "$t" 'MERGE leaves `round_base` alone' "autopilot MERGE keeps the round budget"
  case $t in *'counting on from'*) _fail "no 'counting on from' prose left" ;; *) _pass ;; esac
  assert_contains "$t" '--remove-label resubmitted --remove-label needs-human' "resume removes both labels"
  assert_contains "$t" 'Superseded: dropped' "drop closes open tasks"
  assert_contains "$t" 'is `OPEN`, `gh pr close <pr> --delete-branch' "drop closes only an open PR, deleting its branch"
  assert_contains "$t" "select(.title == \$t)" "out-of-scope beads deduped by title"
  for c in approve rework; do
    s=$(section "$f" "/factory $c")
    assert_contains "$s" 'drain check' "/factory $c ends with the drain check"
  done
  assert_contains "$(tr '\n' ' ' <"$ROOT/factory/agents/approver.md" | tr -s ' ')" 'stays settled in every later round' "approver: owner APPROVE stays settled"
}

test_parallel_drain() {
  local f="$ROOT/.claude/skills/factory/SKILL.md"
  assert_contains "$(section "$SKILL_DIR/adopt.md" '/factory adopt')" 'factory-autopilot' "adopt accepts the drain's claim"
  assert_contains "$(section "$f" '/factory autopilot')" '--jobs' "drain text mentions --jobs"
  assert_contains "$(section "$f" '/factory autopilot' | tr '\n' ' ')" 'is logged instead of ending its worker' "drain text: --watch outlives a failed job"
  assert_contains "$(section "$f" 'Parallel jobs')" 'factory-autopilot' "Parallel jobs names the actor"
  assert_contains "$(section "$SKILL_DIR/resume.md" '/factory resume')" 'BEADS_ACTOR=factory-autopilot' "resume writes Beads as the drain's actor"
  assert_contains "$(cat "$f")" '--if-assignee' "SKILL.md names the drain's compare-and-set"
  assert_contains "$(cat "$ROOT/README.md")" '--jobs' "README documents --jobs"
  assert_contains "$(cat "$ROOT/INSTALL.md")" "\`jobs\`" "INSTALL documents the jobs setting"
  assert_contains "$(tr '\n' ' ' <"$ROOT/INSTALL.md" | tr -s ' ')" 'With `land: "pr"` worktrees branch from `origin/main`, not the local `main`, so the commit must also be pushed' "INSTALL: pr mode needs the install pushed"
}

test_status_command() {
  local s
  s=$(section "$ROOT/.claude/skills/factory/SKILL.md" '/factory status' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" 'one line per job not yet merged or dropped' "status: usage lines for unfinished jobs only"
  assert_contains "$s" '`land: <mode>` (`factory/bin/settings land`' "status prints the land mode"
}

test_resume_open_pr() {
  local s
  s=$(section "$SKILL_DIR/resume.md" '/factory resume' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" '`decision.md` is newer than every file in `round-<N>/`, or `stage` is `autopilot` and `decision_file`'"'"'s first line is `MERGE`' "resume re-runs Merge on an open PR only after a current decision"
  case $s in *'or `autopilot` after a MERGE decision'*) _fail "old open-PR rule is gone" ;; *) _pass ;; esac
}

test_snapshot_before_every_role() {
  local f="$ROOT/.claude/skills/factory/SKILL.md" s
  s=$(section "$f" 'Running a role' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" 'Before any role that has a job folder, whatever its provider, run `factory/bin/beads-snapshot <job folder>`' "snapshot before every role with a job folder"
  case $(tr '\n' ' ' <"$f" | tr -s ' ') in *'Agents only read Beads (`bd --readonly`)'*) _fail "stale bd --readonly wording" ;; *) _pass ;; esac
}

test_prompt_record_and_merge_bookmark() {
  local f="$ROOT/.claude/skills/factory/SKILL.md" update_line delete_line
  assert_contains "$(section "$f" 'Running a role')" 'factory/bin/prompt-record <job folder> <key>' "anthropic roles record their prompt"
  update_line=$(grep -nF 'git update-ref refs/factory/jobs/<job-id> factory/<job-id>' "$f" | head -n 1 | cut -d: -f1)
  delete_line=$(grep -nF 'git branch -D factory/<job-id>' "$f" | head -n 1 | cut -d: -f1)
  assert_contains "$(section "$f" 'Files')" 'Codex and Claude prompts, Codex logs' ".runs lists Claude prompts"
  assert_contains "$(section "$f" 'Files')" 'refs/factory/jobs/<job-id>' "Files lists local job bookmarks"
  if [ -n "$update_line" ] && [ -n "$delete_line" ] && [ "$update_line" -lt "$delete_line" ]; then
    _pass
  else
    _fail "Merge bookmarks the job branch before deleting it" "update-ref line: $update_line" "branch delete line: $delete_line"
  fi
  assert_contains "$(cat "$ROOT/README.md")" 'bin/prompt-record' "README lists prompt-record"
  for module in runs git detail; do
    assert_contains "$(cat "$ROOT/README.md")" "dashboard/$module.js" "README lists dashboard/$module.js"
  done
}

test_dashboard_hints_review() {
  assert_contains "$(cat "$ROOT/factory/dashboard.html")" '`/factory review ${job.id}`' "needs-human card offers /factory review"
}

test_import_conflict_queues_only_free_beads() {
  local s
  s=$(section "$SKILL_DIR/review.md" '/factory review' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" 'if the bead is `in_progress` or assigned to someone else, only `bd update <bead> --remove-label needs-human`' "import conflicts are queued only when nobody has the bead"
}

test_retro_role() {
  local t n
  t=$(tr '\n' ' ' <"$ROOT/factory/agents/retro.md" 2>/dev/null | tr -s ' ')
  for n in 'RETRO: <n> fixes' 'RETRO: nothing to change' \
    '## Cost' '## What each extra attempt was for' '## Fixes' '## Repeats' '## Drafted beads' \
    '`spec`, `plan`, `build`, `review-signal`, `review-batching`, `review-coverage`, `environment`, `flaky`, `external-knowledge`, `owner-scope`, `jev`' \
    '## Lessons from factory jobs' 'retro-rejected.md' 'retro-factory-prs.json' 'retro-stale.txt' 'retro-comment-' \
    'never commit' \
    '1. Before anything else, `AGENTS.md` (or `CLAUDE.md`) in the retro worktree' \
    'Whole, never cut short with `head`, `tail`, `-c` or a line limit: `job.json`, `spec.md`, `plan.json`, `build.md`, and every `decision*.md`, `autopilot-*.md`, `human-*.md`, `human-brief-*.md` and `rework-*.md`' \
    'with every cause that applies (one or more)' \
    'Each distinct cause you found gets an entry in `## Fixes`, or a `- No fix for <cause>: <why>.` line' \
    'That includes every `environment` attempt' \
    'An `external-knowledge` fact that would bite again in this repo is a `repo` lesson' \
    'For each review lens, count the rounds where it had nothing to review or found nothing' \
    'A lens idle on most rounds is `review-coverage`' \
    'leaving out `role: "retro"` rows' \
    'Each entry starts `<k>. kind: repo.`, `<k>. kind: factory.` or `<k>. kind: work.` exactly'; do
    assert_contains "$t" "$n" "retro role mentions $n"
  done
  case $t in *'Facts that only matter to this job stay out'*) _fail "retro role drops the old job-only facts rule" ;; *) _pass ;; esac
  case $t in *SQS* | *CDK* | *garmin*) _fail "retro role is not tuned to one job" ;; *) _pass ;; esac
  assert_eq "sonnet" "$(jq -r '.retro.model // empty' "$ROOT/factory/models.json")" "models.json has retro on sonnet"
}

test_retro_wiring() {
  local f="$ROOT/.claude/skills/factory/SKILL.md" t s n
  t=$(skill_text | tr '\n' ' ' | tr -s ' ')
  assert_contains "$(sed -n 3p "$f")" '/factory retro' "description lists /factory retro"
  s=$(section "$SKILL_DIR/retro.md" '/factory retro <job-id>' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" '## /factory retro <job-id>' "SKILL.md has /factory retro <job-id>"
  assert_contains "$s" 'skip `retro-due`' "/factory retro skips retro-due"
  assert_contains "$s" 'If `job.json` `retro_worktree` is not null and `retro.md`'"'"'s first line passes step 4, a publish was cut off: run only step 5 and step 6 (`factory/bin/retro-publish <job folder>`), not prep or the role.' "/factory retro finishes a cut-off publish alone"
  assert_contains "$t" 'It prints three lines: `repo <path>`, `factory <path> <kind>`, then `base <ref>`.' "Retro step names prep's three lines"
  assert_contains "$t" 'and `<ref>` from the `base` line as `<paths>`'"'"' Base' "Retro step uses the base line for <paths>' Base"
  for n in 'factory/bin/retro-due <job folder>' 'factory/bin/retro-prep <job folder>' \
    'factory/bin/retro-publish <job folder>' 'usage-record claude <job folder> retro' \
    'A retro never changes `stage` or `situation`' 'retro_pr'; do
    assert_contains "$t" "$n" "SKILL.md mentions $n"
  done
  s=$(awk '/^### Merge$/ {on = 1} on && /^- \*\*0\*\*/ {b = 1} on && /^- \*\*6\*\*/ {exit} b' "$f")
  assert_contains "$(printf '%s' "$s" | tr '\n' ' ' | tr -s ' ')" '**Retro**, then `factory/bin/usage-record session <job folder>`' "Merge exit 0 runs the Retro before usage-record session"
  s=$(awk '/^ *- \*\*DROP\*\*/ {b = 1} b && /^6\. / {exit} b' "$SKILL_DIR/resume.md")
  assert_contains "$(printf '%s' "$s" | tr '\n' ' ' | tr -s ' ')" '**Retro**, then `factory/bin/usage-record session <job folder>`' "resume DROP runs the Retro before usage-record session"
  assert_contains "$t" 'stop the retro; `/factory retro <job-id>` finishes it later. The job stays where it is, and a drain' "a failed retro stops only the retro"
  assert_contains "$(cat "$ROOT/README.md")" 'factory_source' "README documents factory_source"
  assert_contains "$(cat "$ROOT/INSTALL.md")" 'factory_source' "INSTALL documents factory_source"
}

test_jev_wiring() {
  local f="$ROOT/.claude/skills/factory/SKILL.md" t s n a
  t=$(tr '\n' ' ' <"$f" | tr -s ' ')
  for n in 'factory/bin/jev-decide route <job folder> <task-id>' 'factory/bin/jev-decide reviewers <job folder> <N>' \
    'factory/bin/jev-decide triage <job folder> <N>' '### Triage' 'Fix round N notes' 'discovered-from:<bead>' \
    '`PASS` or `SKIPPED`'; do
    assert_contains "$t" "$n" "SKILL.md mentions $n"
  done
  s=$(awk '/^### Jev$/ {on = 1; print; next} on && /^##/ {exit} on' "$f" | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" 'never override' "Jev section says never override"
  s=$(awk '/^### Review round N$/ {on = 1} on && /^### Approve$/ {exit} on' "$f" | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" '`SKIPPED` counts as `PASS`' "Review round N step 5 counts SKIPPED as PASS"
  assert_contains "$s" 'N - round_base < MAX_ROUNDS' "Review round N step 5 bounds Triage by MAX_ROUNDS"
  s=$(awk '/^### Triage$/ {on = 1; print; next} on && /^##/ {exit} on' "$f" | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" 'skips the approver and autopilot' "Triage skips the approver and autopilot"
  assert_contains "$s" 'If it prints `off`, or `round-<N>/triage.json` doesn'"'"'t exist, go to **Approve**.' "Triage goes to Approve when off or no file"
  assert_contains "$s" 'open child of the job bead with the same title' "Triage dedupes the fix tasks by title"
  s=$(awk '/^### Autopilot decision$/ {on = 1; print; next} on && /^##/ {exit} on' "$f" | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" '`PASS` or `SKIPPED`' "Autopilot decision MERGE accepts SKIPPED"
  s=$(section "$f" '/factory approve <job-id>' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" '`PASS` or `SKIPPED`' "/factory approve accepts SKIPPED"
  assert_contains "$(tr '\n' ' ' <"$ROOT/factory/agents/approver.md" | tr -s ' ')" 'not a reason to escalate' "approver: SKIPPED is not a reason to escalate"
  for a in autopilot briefer; do
    assert_contains "$(tr '\n' ' ' <"$ROOT/factory/agents/$a.md" | tr -s ' ')" 'not a reason to hold back' "$a: SKIPPED is not a reason to hold back"
  done
  assert_contains "$(cat "$ROOT/factory/agents/approver.md")" 'triage.md' "approver reads triage.md"
  assert_contains "$(cat "$ROOT/factory/agents/approver.md")" 'VERDICT: SKIPPED' "approver accepts SKIPPED"
  for a in autopilot briefer; do
    assert_contains "$(cat "$ROOT/factory/agents/$a.md")" 'SKIPPED' "$a mentions SKIPPED"
  done
  for a in security code ux ui adversarial; do
    assert_contains "$(cat "$ROOT/factory/agents/reviewer-$a.md")" 'VERDICT: SKIPPED' "reviewer-$a mentions SKIPPED"
  done
  assert_contains "$(tr '\n' ' ' <"$ROOT/factory/autopilot-policy.md" | tr -s ' ')" 'every final-round review `PASS` or `SKIPPED`' "policy: MERGE accepts SKIPPED"
  assert_contains "$(cat "$ROOT/factory/agents/approver.md")" 'PASS or SKIPPED' "approver intro accepts SKIPPED"
  assert_contains "$(cat "$ROOT/factory/autopilot-policy.md")" 'SKIPPED' "policy mentions SKIPPED"
  assert_contains "$(cat "$ROOT/factory/agents/retro.md")" 'jev.jsonl' "retro reads jev.jsonl"
  assert_contains "$(cat "$ROOT/INSTALL.md")" 'JEV_KEY' "INSTALL documents JEV_KEY"
  assert_contains "$(cat "$ROOT/README.md")" 'bin/jev-decide' "README lists bin/jev-decide"
}

test_roles_not_repo_specific() {
  local hits
  hits=$(cd "$ROOT" && grep -niwE 'pnpm|npm|yarn|vitest|jest|eslint|pytest|cargo|SQS|CDK|garmin' factory/agents/*.md .claude/agents/factory-agent.md)
  assert_eq "" "$hits" "role files name no project's toolchain; that lives in the target's AGENTS.md"
}

test_repo_agents_md() {
  local a n tests
  a=$(cat "$ROOT/AGENTS.md" 2>/dev/null)
  assert_eq "@AGENTS.md" "$(cat "$ROOT/CLAUDE.md" 2>/dev/null)" "CLAUDE.md is the one line @AGENTS.md"
  assert_contains "$a" 'factory/test/run' "AGENTS.md says how to run the tests"
  # Each invariant line names the prose test that enforces it as `test_<name>`.
  for n in test_no_literal_main_diffs test_roles_skip_bd test_agents_rule; do
    assert_contains "$a" "\`$n\`" "AGENTS.md names $n"
  done
  tests=$(cat "$LIB_DIR"/*.test.sh | grep -oE '^test_[a-z0-9_]+\(\)' | tr -d '()')
  for n in $(printf '%s' "$a" | grep -oE '`test_[a-z0-9_]+`' | tr -d '`' | sort -u); do
    case $'\n'"$tests"$'\n' in *$'\n'"$n"$'\n'*) _pass ;; *) _fail "AGENTS.md names $n, which no test file defines" ;; esac
  done
}

test_seeded_adrs() {
  local f i=1 want t
  set -- "$ROOT"/docs/adr/[0-9][0-9][0-9][0-9]-*.md
  [ -e "$1" ] || { _fail "docs/adr holds numbered ADRs"; return; }
  for f; do
    want=$(printf '%04d' "$i")
    assert_eq "$want" "$(basename "$f" | cut -c1-4)" "ADRs are numbered from 0001 without gaps"
    t=$(cat "$f")
    for h in '## Context' '## Decision' '## Why'; do
      assert_contains "$t" "$h" "$(basename "$f") has $h"
    done
    i=$((i + 1))
  done
}

test_skill_pointers() {
  local dir="$ROOT/.claude/skills/factory" f="$ROOT/.claude/skills/factory/SKILL.md" links l c line
  links=$(grep -oE '\]\([^)#:]+\.md\)' "$f" | sed -E 's/^\]\(//; s/\)$//' | sort -u)
  [ -n "$links" ] || _fail "SKILL.md links at least one skill file"
  for l in $links; do
    if [ -f "$dir/$l" ]; then _pass; else _fail "SKILL.md pointer $l resolves to a file in the skill folder"; fi
  done
  for c in import adopt review retro resume; do
    line=$(grep -F "Read [$c.md]($c.md)" "$f" | head -n 1)
    assert_contains "$line" "/factory $c" "SKILL.md points at $c.md and says when to read it"
    assert_contains "$(head -n 1 "$dir/$c.md" 2>/dev/null)" "## /factory $c" "$c.md starts with its command heading"
    case $(section "$f" "/factory $c" | tr '\n' ' ' | tr -s ' ') in
      *'1. '* | *'- '*) _fail "SKILL.md no longer carries the /factory $c steps" ;; *) _pass ;; esac
  done
}

test_install_guide_points_at_script() {
  local s
  s=$(awk '/^## 3\./ {on = 1} on && /^## 4\./ {exit} on' "$ROOT/INSTALL.md")
  assert_contains "$s" 'factory/bin/install <target>' "INSTALL step 3 runs the install script"
  assert_contains "$s" 'factory/manifest' "INSTALL step 3 names the manifest"
  assert_contains "$s" 'factory/VERSION' "INSTALL step 3 names the version file"
  case $s in *rsync*) _fail "INSTALL step 3 no longer copies by hand" ;; *) _pass ;; esac
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
