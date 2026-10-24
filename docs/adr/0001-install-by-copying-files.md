# 1. Install by copying files into the target repo

## Context

The factory has to run inside each target repo: the orchestrator reads
`.claude/skills/factory/SKILL.md`, roles run in the target's worktrees, and
scripts in `factory/bin/` run from its root. It could get there as a Claude
Code plugin, a git submodule, a symlink to one checkout, or plain copies.

## Decision

`INSTALL.md` copies `.claude/skills/factory/`, `.claude/agents/factory-agent.md`
and `factory/` into the target, where they are committed. An upgrade is a
`diff -r` against the source, reviewed with the user, that keeps the target's
own `models.json` and `autopilot-policy.md`.

## Why

Targets customise the factory (models, autopilot policy, settings), and a job
must run the factory version its repo committed, in a fresh worktree and
inside the Codex sandbox, with nothing outside the repo to resolve. A plugin
or symlink would share one version across every repo and reach outside the
worktree; a submodule adds a checkout step every worktree and sandbox must get
right. The cost is drift: fixes don't flow back on their own, and upgrades are
manual. Retros cover the return path by opening factory fixes as a PR on the
checkout named by `factory_source`, else leaving `retro-factory.patch`.
Moving off copies later means migrating every installed repo and the
customisations in each.
