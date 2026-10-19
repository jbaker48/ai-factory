#!/usr/bin/env bash
# Checks on the prose the orchestrator and roles read (SKILL.md, role files, template).
# shellcheck source=/dev/null
# shellcheck disable=SC2016 # backticks in the needles are literal Markdown
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$FACTORY_SRC/.." && pwd)

test_no_literal_main_diffs() {
  local hits
  hits=$(cd "$ROOT" && grep -nE '(main\.\.|main\.\.\.|merge-tree --write-tree (origin/)?main|--base main)' factory/agents/*.md factory/bin/* .claude/skills/factory/SKILL.md)
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

test_codex_roles_skip_bd() {
  local hits
  hits=$(cd "$ROOT" && grep -l 'bd --readonly' factory/agents/{approver,autopilot,reviewer-security,builder}.md)
  assert_eq "" "$hits" "Codex roles read beads.md, not bd"
}

test_dashboard_reads_usage() {
  grep -q "usage.jsonl" "$ROOT/factory/dashboard.html"
  assert_eq "0" "$?" "dashboard reads usage.jsonl"
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
  t=$(cat "$f")
  assert_contains "$t" '## /factory review' "SKILL.md has /factory review"
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
  t=$(tr '\n' ' ' <"$f" | tr -s ' ')
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
  assert_contains "$(section "$f" '/factory adopt')" 'factory-autopilot' "adopt accepts the drain's claim"
  assert_contains "$(section "$f" '/factory autopilot')" '--jobs' "drain text mentions --jobs"
  assert_contains "$(section "$f" 'Parallel jobs')" 'factory-autopilot' "Parallel jobs names the actor"
  assert_contains "$(section "$f" '/factory resume')" 'BEADS_ACTOR=factory-autopilot' "resume writes Beads as the drain's actor"
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
  s=$(section "$ROOT/.claude/skills/factory/SKILL.md" '/factory resume' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" '`decision.md` is newer than every file in `round-<N>/`, or `stage` is `autopilot` and `decision_file`'"'"'s first line is `MERGE`' "resume re-runs Merge on an open PR only after a current decision"
  case $s in *'or `autopilot` after a MERGE decision'*) _fail "old open-PR rule is gone" ;; *) _pass ;; esac
}

test_snapshot_before_every_role() {
  local f="$ROOT/.claude/skills/factory/SKILL.md" s
  s=$(section "$f" 'Running a role' | tr '\n' ' ' | tr -s ' ')
  assert_contains "$s" 'Before any role that has a job folder, whatever its provider, run `factory/bin/beads-snapshot <job folder>`' "snapshot before every role with a job folder"
  case $(tr '\n' ' ' <"$f" | tr -s ' ') in *'Agents only read Beads (`bd --readonly`)'*) _fail "stale bd --readonly wording" ;; *) _pass ;; esac
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
