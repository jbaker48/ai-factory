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
  assert_contains "$(grep -m 1 '^description:' "$f")" ' review,' "description lists /factory review"
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
  assert_contains "$(cat "$SKILL_DIR/setup.md")" "\`jobs\`" "setup.md documents the jobs setting"
  assert_contains "$(tr '\n' ' ' <"$SKILL_DIR/setup.md" | tr -s ' ')" 'With `land: "pr"` worktrees branch from `origin/main`, not the local `main`, so the commit must also be pushed' "setup.md: pr mode needs the install pushed"
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
  assert_contains "$(grep -m 1 '^description:' "$f")" ' retro,' "description lists /factory retro"
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
  assert_contains "$(cat "$SKILL_DIR/setup.md")" 'factory_source' "setup.md documents factory_source"
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
  assert_contains "$(cat "$SKILL_DIR/setup.md")" 'JEV_KEY' "setup.md documents JEV_KEY"
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
  for c in import adopt review retro resume setup; do
    line=$(grep -F "Read [$c.md]($c.md)" "$f" | head -n 1)
    assert_contains "$line" "/factory $c" "SKILL.md points at $c.md and says when to read it"
    assert_contains "$(head -n 1 "$dir/$c.md" 2>/dev/null)" "## /factory $c" "$c.md starts with its command heading"
    case $(section "$f" "/factory $c" | tr '\n' ' ' | tr -s ' ') in
      *'1. '* | *'- '*) _fail "SKILL.md no longer carries the /factory $c steps" ;; *) _pass ;; esac
  done
}

test_install_guide_points_at_script() {
  local s
  s=$(awk '/^## 2\./ {on = 1} on && /^## 3\./ {exit} on' "$ROOT/INSTALL.md")
  assert_contains "$s" 'factory/bin/install <target>' "INSTALL step 2 runs the install script"
  assert_contains "$s" 'factory/manifest' "INSTALL step 2 names the manifest"
  assert_contains "$s" 'factory/VERSION' "INSTALL step 2 names the version file"
  assert_contains "$s" 'factory/bin/upgrade <target>' "INSTALL step 2 previews an upgrade"
  case $s in *rsync*) _fail "INSTALL step 2 no longer copies by hand" ;; *) _pass ;; esac
}

# INSTALL.md is the tool check, the install script and /factory setup; the
# decisions live in setup.md.
test_install_guide_is_three_steps() {
  local t steps n
  t=$(flat "$(cat "$ROOT/INSTALL.md")")
  steps=$(grep -E '^## [0-9]+\. ' "$ROOT/INSTALL.md")
  assert_eq "## 1. Check the tools
## 2. Run the install script
## 3. Run /factory setup" "$steps" "INSTALL has three steps"
  assert_contains "$(awk '/^## 3\./ {on = 1} on' "$ROOT/INSTALL.md")" '`/factory setup`' "INSTALL step 3 runs /factory setup"
  assert_contains "$t" 'ships its own references and needs no external skills plugin' "INSTALL: no external skills plugin"
  for n in 'bd init' 'factory_source' 'JEV_KEY' 'priority_labels' 'factory/bin/models'; do
    case $t in *"$n"*) _fail "INSTALL leaves $n to /factory setup" ;; *) _pass ;; esac
  done
}

test_setup_decisions() {
  local s t n
  s=$(awk '/^### 3\. Decisions/ {on = 1} on && /^### 4\./ {exit} on' "$SKILL_DIR/setup.md")
  t=$(flat "$s")
  for n in '**Autopilot policy**' '**Model preset**' '**Settings**' "**Jev's send mode**" '**Install commit**'; do
    assert_contains "$t" "$n" "setup.md Decisions presents $n"
  done
  for n in 'factory/bin/decisions' 'as the default' 'wait for their answer' \
    'factory/autopilot-policy.md' 'factory/bin/models mixed' 'factory/bin/models claude' 'factory/bin/models openai' \
    'factory/settings.example.json' '"land": "pr"' '"land": "local"' 'priority_labels' '`jobs`' 'factory_source' \
    'metadata' 'summary' '"send": "off"' 'JEV_KEY' \
    'With `land: "pr"` worktrees branch from `origin/main`, not the local `main`, so the commit must also be pushed' \
    '**Done when** the user has answered all five, and each answer is in its file or committed.'; do
    assert_contains "$t" "$n" "setup.md Decisions mentions $n"
  done
  case $t in *'headless'*) _pass ;; *) _fail "setup.md Decisions says what a headless session does" ;; esac
}

test_template_domain_docs() {
  local s
  s=$(section "$ROOT/factory/AGENTS.template.md" 'Domain docs' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" '## Domain docs' "AGENTS template has a Domain docs section"
  assert_contains "$s" 'Glossary:' "Domain docs points at the glossary"
  assert_contains "$s" 'ADRs:' "Domain docs points at the ADR folder"
  assert_contains "$s" 'Delete this section if the repo has neither' "Domain docs is removable"
}

test_roles_read_domain_docs() {
  local r t
  for r in spec-writer planner builder; do
    t=$(tr '\n' ' ' <"$ROOT/factory/agents/$r.md" | tr -s ' ')
    assert_contains "$t" 'The domain docs `## Domain docs` in AGENTS.md points at, when they exist' "$r reads the domain docs"
    assert_contains "$t" "the glossary's terms" "$r uses the glossary's terms"
  done
}

# Roles read the glossary; none writes to it.
test_no_role_writes_glossary() {
  local f t
  for f in "$ROOT"/factory/agents/*.md; do
    t=$(tr '\n' ' ' <"$f" | tr -s ' ')
    case $t in
      *[Gg]lossary*) assert_contains "$t" 'never edit the glossary' "$(basename "$f") never edits the glossary" ;;
    esac
  done
  assert_contains "$(tr '\n' ' ' <"$ROOT/factory/agents/retro.md" | tr -s ' ')" 'never edit the glossary' "retro's repo fixes leave the glossary alone"
}

test_retro_suggests_adrs() {
  local t n
  t=$(tr '\n' ' ' <"$ROOT/factory/agents/retro.md" | tr -s ' ')
  for n in '## ADR candidates' \
    'Suggest an ADR only when all three tests hold' \
    'hard to reverse' 'surprising without context' 'a real trade-off' \
    '- <decision>: hard to reverse: <why>; surprising without context: <why>; real trade-off: <why>. Evidence: <file>' \
    'Suggest; never write the ADR'; do
    assert_contains "$t" "$n" "retro ADR suggestions mention $n"
  done
}

test_approver_names_candidate_adr() {
  local s
  s=$(awk '/^## For the human$/ {on = 1} on && /^```$/ {exit} on' "$ROOT/factory/agents/approver.md" | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" 'Candidate ADR: <decision>' "approver's escalation brief can name a candidate ADR"
  assert_contains "$(tr '\n' ' ' <"$ROOT/factory/agents/approver.md" | tr -s ' ')" 'all three tests hold' "approver names an ADR only when all three tests hold"
}

# flat <text>: one line, runs of spaces squeezed, so a needle survives rewrapping.
flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }

test_setup_command() {
  local s
  s=$(flat "$(cat "$SKILL_DIR/setup.md" 2>/dev/null)")
  assert_contains "$(grep -m 1 '^description:' "$SKILL_DIR/SKILL.md")" ' setup.' "description lists /factory setup"
  assert_contains "$s" '**Done when** `bd --readonly ready` runs in the target without an error.' "setup.md's Beads step has its Done when"
  assert_contains "$s" '**Done when** `AGENTS.md` has no `<...>` left, every command in it passed in the fresh worktree (or the user has accepted a named failure), and the dev server bound exactly port `5199`.' "setup.md's AGENTS.md step has its Done when"
  assert_contains "$s" 'bd init' "setup.md initialises Beads when there is none"
  assert_contains "$s" 'factory/bin/agents-md apply AGENTS.md' "setup.md merges factory sections with the script"
  assert_contains "$s" 'factory/bin/agents-md check' "setup.md proves the commands in a fresh worktree with the script"
  assert_contains "$s" 'factory/AGENTS.template.md' "setup.md starts from the template"
  assert_contains "$s" 'bd --readonly' "setup.md scopes Beads' instructions: agents read Beads only"
}

test_template_sections_marked() {
  local t=$ROOT/factory/AGENTS.template.md body
  # Every heading after the header comment sits inside a factory section.
  body=$(awk '/^-->$/ {on = 1; next} on' "$t" | awk '
    /^<!-- factory:begin [^ ]+ -->$/ {cur = $3; next}
    /^<!-- factory:end [^ ]+ -->$/ {if ($3 == cur) cur = ""; next}
    /^#/ && cur == "" {print}')
  assert_eq "" "$body" "every template heading is inside a factory section"
  assert_exit 0 "template markers are balanced (agents-md apply accepts it)" -- \
    "$ROOT/factory/bin/agents-md" apply "$TEST_TMP/template-out.md" "$t"
  assert_contains "$(cat "$TEST_TMP/template-out.md" 2>/dev/null)" '<!-- factory:begin setup -->' "template has a setup section"
}

test_user_invoked_only() {
  local f="$ROOT/.claude/skills/factory/SKILL.md" fm d t
  fm=$(awk 'NR == 1 && /^---$/ {on = 1; next} on && /^---$/ {exit} on' "$f")
  assert_contains "$fm" 'disable-model-invocation: true' "the factory skill runs only when typed"
  d=$(printf '%s\n' "$fm" | grep '^description:')
  assert_eq "1" "$(printf '%s\n' "$fm" | grep -c '^description:')" "the skill has one description line"
  case $d in *'Use when'*) _fail "the description is for people, not model triggers" "$d" ;; *) _pass ;; esac
  if [ "${#d}" -le 200 ]; then _pass; else _fail "the description is one short line" "${#d} chars"; fi
  t=$(tr '\n' ' ' <"$f" | tr -s ' ')
  assert_contains "$t" "use only the factory's own roles and scripts" "the orchestrator stays in the factory loop"
}

# The builder writes a failing test first for behaviour-changing tasks (issue #15).
test_builder_test_first() {
  local b ev
  b=$(tr '\n' ' ' <"$ROOT/factory/agents/builder.md" | tr -s ' ')
  assert_contains "$b" 'write a test that fails' "builder writes a failing test first"
  assert_contains "$b" 'before you write the code' "builder writes the test before the code"
  assert_contains "$b" 'docs, config and the final check' "builder names the exempt tasks"
  assert_contains "$b" '`factory/testing.md`' "builder points at the testing reference"
  ev=$(awk '/^## Evidence/ {on = 1; next} on && /^## / {exit} on' "$ROOT/factory/agents/builder.md" | tr '\n' ' ' | tr -s ' ')
  assert_contains "$ev" 'failing run' "Evidence shows the failing run"
  case $ev in *'failing run'*'passing run'*) _pass ;; *) _fail "Evidence puts the failing run before the passing run" ;; esac
}

test_testing_reference() {
  local r
  r=$(tr '\n' ' ' <"$ROOT/factory/testing.md" 2>/dev/null | tr -s ' ')
  assert_contains "$r" 'through the public interface' "reference: test behaviour through the public interface"
  assert_contains "$r" 'Mock only at system boundaries' "reference: mock only at system boundaries"
  assert_contains "$r" 'independent source' "reference: expected values from an independent source"
  assert_contains "$r" 'Implementation-coupled' "reference names implementation-coupled tests"
  assert_contains "$r" 'Tautological' "reference names tautological tests"
}

test_code_reviewer_checks_tests() {
  local r
  r=$(tr '\n' ' ' <"$ROOT/factory/agents/reviewer-code.md" | tr -s ' ')
  assert_contains "$r" '`factory/testing.md`' "code reviewer points at the testing reference"
  assert_contains "$r" 'coupled to the implementation' "code reviewer flags implementation-coupled tests"
  assert_contains "$r" 'tautological' "code reviewer flags tautological tests"
}

test_spec_writer_asks_for_tests() {
  local s
  s=$(tr '\n' ' ' <"$ROOT/factory/agents/spec-writer.md" | tr -s ' ')
  assert_contains "$s" 'If the repo has a test runner, ask for tests' "spec-writer asks for tests whenever there is a runner"
  case $s in *'Ask for new tests only if'*) _fail "spec-writer no longer makes tests optional" ;; *) _pass ;; esac
}

# Each task names its seam; the orchestrator files it and the builder tests there (issue #18).
test_planner_names_seams() {
  local p
  p=$(tr '\n' ' ' <"$ROOT/factory/agents/planner.md" | tr -s ' ')
  assert_contains "$p" '"seam": {' "plan format carries a seam field"
  assert_contains "$p" '"interface":' "seam names the interface"
  assert_contains "$p" '"catches":' "seam says what a test there catches"
  assert_contains "$p" '"misses":' "seam says what a test there misses"
  assert_contains "$p" 'Every task that changes behaviour names its `seam`' "planner requires a seam for behaviour-changing tasks"
}

test_orchestrator_files_seam() {
  local s
  s=$(skill_text | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" 'factory/bin/task-description <job folder>/plan.json <key>' "orchestrator builds the task description with task-description"
  assert_contains "$s" 'a seam' "orchestrator check covers seam shape"
}

test_builder_tests_at_seam() {
  local b
  b=$(tr '\n' ' ' <"$ROOT/factory/agents/builder.md" | tr -s ' ')
  assert_contains "$b" "at the task's seam" "builder writes its failing test at the seam"
  assert_contains "$b" "can't be tested as given" "builder reports BLOCKED on an untestable seam"
}

test_code_review_traceable() {
  local f="$ROOT/factory/agents/reviewer-code.md" t
  t=$(tr '\n' ' ' <"$f" | tr -s ' ')
  assert_contains "$t" 'Every CHANGES finding cites its source' "code review findings cite a source"
  assert_contains "$t" 'an acceptance-criterion number from spec.md' "code review cites a criterion number"
  assert_contains "$t" 'a rule in AGENTS.md' "code review cites an AGENTS.md rule"
  assert_contains "$(section "$f" 'What to look for')" '**Scope creep**' "scope creep is its own check"
  assert_contains "$t" 'cites the spec.md section it goes beyond' "scope creep cites the spec section"
  local smells
  smells=$(section "$f" 'Smell baseline')
  assert_eq "12" "$(grep -cE '^- \*\*[^*]+\*\*: .+ Fix: .+' <<<"$smells")" "smell baseline lists 12 smells, each with its fix"
  smells=$(tr '\n' ' ' <<<"$smells" | tr -s ' ')
  assert_contains "$smells" 'A smell goes under Notes, never under Findings' "smells go to Notes only"
  assert_contains "$smells" 'never makes the verdict CHANGES' "a smell never blocks on its own"
  assert_contains "$smells" 'A rule documented in AGENTS.md overrides this baseline' "a repo rule overrides the baseline"
}

# Seam choices get checked against a shipped design reference (issue #19).
test_design_reference() {
  local r
  r=$(tr '\n' ' ' <"$ROOT/factory/design.md" 2>/dev/null | tr -s ' ')
  assert_contains "$r" 'deep modules' "design reference: deep modules"
  assert_contains "$r" 'deletion test' "design reference: the deletion test"
  assert_contains "$r" 'One adapter is a hypothetical seam; two make it real' "design reference: one adapter is hypothetical"
  assert_contains "$r" 'The interface is the test surface' "design reference: the interface is the test surface"
}

test_planner_reads_design_reference() {
  local p
  p=$(tr '\n' ' ' <"$ROOT/factory/agents/planner.md" | tr -s ' ')
  assert_contains "$p" 'choose each seam with `factory/design.md`' "planner points at the design reference when choosing seams"
}

test_adversarial_checks_seams() {
  local f="$ROOT/factory/agents/reviewer-adversarial.md" t
  t=$(tr '\n' ' ' <"$f" | tr -s ' ')
  assert_contains "$t" '`factory/design.md`' "adversarial reviewer points at the design reference"
  assert_contains "$t" '`plan.json`' "adversarial reviewer reads the planned seams"
  t=$(section "$f" 'What to look for' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$t" 'testing past the interface' "adversarial reviewer flags tests past the interface"
  assert_contains "$t" 'single-adapter seams' "adversarial reviewer flags single-adapter seams"
  assert_contains "$t" 'shallow pass-through modules' "adversarial reviewer flags shallow pass-through modules"
}

test_escalation_lists_seams() {
  local a b
  a=$(tr '\n' ' ' <"$ROOT/factory/agents/approver.md" | tr -s ' ')
  assert_contains "$a" "each task's seam" "approver's escalation brief lists each task's seam"
  b=$(tr '\n' ' ' <"$ROOT/factory/agents/briefer.md" | tr -s ' ')
  assert_contains "$b" "each task's seam" "briefer's brief lists each task's seam"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
