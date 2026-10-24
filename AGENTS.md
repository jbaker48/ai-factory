# AI Factory

A software factory for Claude Code: `/factory <feature>` takes a feature
through spec, plan, build, review and approve, with Beads tracking the work and
Claude and OpenAI models doing it. This repo is the factory's source. Target
repos get a copy of `.claude/` and `factory/` (see `INSTALL.md`). Bash and
`jq` for the scripts, Node for the dashboard, Markdown for everything the
orchestrator and roles read.

## Tests

```bash
factory/test/run                      # every factory/test/*.test.sh
bash factory/test/prose.test.sh       # one file
```

Each file prints `N passed, M failed` and exits non-zero on a failure. They
need `bash`, `git`, `jq` and `node`, and run offline: `lib.sh` gives each file
a private `HOME`, git config and stub `PATH`, so they never touch your real
`~/.claude`, `~/.codex` or Beads. `factory/test/prose.test.sh` checks the
prose in `SKILL.md` and its subcommand files, the role files, the template,
`README.md` and `INSTALL.md`; a wording change there may need its needle updated.

## Invariants

The factory enforces these on the repos it runs in, so work on the factory
follows them too. Where a prose test enforces one, it is named.

- **Role files carry nothing repo-specific.** `factory/agents/*.md` and
  `.claude/agents/factory-agent.md` get setup, ports, validation commands and
  conventions from the target's `AGENTS.md`, never from the role file. No
  project's toolchain, service or job belongs in them. Enforced by
  `test_roles_not_repo_specific` and, for the retro role, `test_retro_role`.
- **Roles never call `bd`.** Any role may run in the Codex sandbox, which
  can't open the Beads lock. Roles read `<job folder>/beads.md`, the snapshot
  the orchestrator takes before every role; only the orchestrator writes to
  Beads, from the main checkout. Enforced by `test_roles_skip_bd` and
  `test_snapshot_before_every_role`.
- **Nothing diffs against a literal `main`.** Every role gets `Base: <base>.`
  in its prompt, and scripts take the base from `factory/settings.json`
  (`origin/main` in `pr` mode, `main` in `local` mode). Enforced by
  `test_no_literal_main_diffs` and `test_prompt_has_base`.
- **No agent commits or pushes.** Builders list their files and a commit
  message; the orchestrator commits. The target template says the same, and
  that only the Merge step commits to `main` in local land mode. Enforced by
  `test_agents_rule`.
- **Acceptance criteria live only in `spec.md`.** Beads tracks the work and
  every task points back at the criteria it covers. Not enforced by a test.

## Layout

- `.claude/skills/factory/SKILL.md`: the orchestrator. The session running
  `/factory` follows it.
- `.claude/agents/factory-agent.md`: the one thin subagent every Claude role
  runs through.
- `factory/agents/`: one role file per role, read by both providers.
- `factory/bin/`: the scripts the orchestrator runs. Each starts with a usage
  comment.
- `factory/models.json`, `factory/presets/`: which model runs each role.
- `factory/jev/`: questions and settings for Jev's routing, triage and
  reviewer decisions.
- `factory/dashboard.html`, `factory/dashboard/`, `factory/bin/dashboard`:
  the local dashboard.
- `factory/AGENTS.template.md`: the template a target's `AGENTS.md` is
  written from, by `/factory setup` (`.claude/skills/factory/setup.md`).
  Shipped to targets; no job reads it. Its `factory:begin`/`factory:end`
  markers are what `factory/bin/agents-md apply` updates on a re-run.
- `factory/test/`: the tests.
- `docs/superpowers/specs/`, `docs/superpowers/plans/`: designs and plans.
- `docs/adr/`: decisions that are hard to reverse. Read them before changing
  the area they cover.

## Docs to keep current

- `README.md` when a command, script, role or setting changes.
- `INSTALL.md` when what gets copied changes, and
  `.claude/skills/factory/setup.md` (with `factory/bin/decisions`) when a
  decision or setting `/factory setup` asks about changes.
- `factory/AGENTS.template.md` when a condition target commands run under
  changes.
- A new ADR in `docs/adr/`, numbered after the last, when a decision is hard
  to reverse, surprising without context, and the result of a real trade-off.
