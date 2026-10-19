#!/usr/bin/env bash
# Checks on the prose the orchestrator and roles read (SKILL.md, role files, template).
# shellcheck source=/dev/null
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

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
finish
