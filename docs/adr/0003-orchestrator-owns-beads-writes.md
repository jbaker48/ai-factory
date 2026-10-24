# 3. Only the orchestrator touches Beads; roles read a snapshot

## Context

Beads holds the queue and each job's tasks, and roles need that state: the
approver checks gates, builders read their task, the autopilot reads what's
open. Codex roles run in a sandbox that can't open the Beads lock, so
`bd --readonly` failed there and the approver escalated on gates it couldn't
verify (`docs/findings/2026-10-19-token-efficiency-first-run.md`). Parallel
jobs would also contend for the lock.

## Decision

No role calls `bd`, on either provider. Before every role with a job folder
the orchestrator runs `factory/bin/beads-snapshot`, which writes `beads.md`,
and roles read that. The orchestrator makes every Beads write, from the main
checkout; the autopilot drain claims beads with a compare-and-set as the actor
`factory-autopilot`. `test_roles_skip_bd` keeps role files from drifting back.

## Why

One writer outside the sandbox means every role works on both providers and
parallel sessions never fight over the lock. The trade-off: a role sees state
as of the snapshot, not live, and the orchestrator carries an extra step
before every role and owns all the bookkeeping. Letting only Claude roles call
`bd` would have been simpler for them, but any role can move to Codex, so the
rule has to hold for all. Reversing it touches every role file and the drain's
claim logic.
