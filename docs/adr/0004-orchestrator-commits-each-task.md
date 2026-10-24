# 4. Agents never commit; the orchestrator commits each task

## Context

Builders change files on the job branch, and the natural thing is for each to
commit its own work. But the Codex sandbox keeps `.git` read-only, and agents
that commit and push also commit stray files, rewrite history or push to
`main`.

## Decision

No agent commits or pushes. A builder lists the files it changed and a commit
message; the orchestrator commits each task as one commit whose subject ends
with its bead id, `Add limiter middleware (app-k2f.1)`. Only the Merge step
lands on `main`. The target `AGENTS.md` template says the same, and
`test_agents_rule` checks it.

## Why

It is the only rule that works inside the sandbox, and it gives one commit per
task with a predictable subject, which the dashboard uses to find each task's
diff. The cost: builders can't checkpoint partial work in git, and a wrong
file list means a commit that misses files. Letting agents commit would mean
giving up the sandbox's read-only `.git` and the task-to-commit mapping the
dashboard depends on.
