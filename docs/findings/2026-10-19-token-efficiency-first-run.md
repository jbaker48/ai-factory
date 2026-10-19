# Finding: token efficiency of the first autopilot job

- Date: 2026-10-19
- Source run: garmin-ai-coach job `001-event-bus-tenant-boundary` (bead `garmin-ai-coach-903`), `/factory autopilot adopt`, headless
- State when measured: round 2, verification task in progress after one autopilot REWORK
- Data: `factory/jobs/<job>/.runs/*.jsonl` (Codex `turn.completed` usage) and the Claude Code session transcripts for the orchestrator and its subagents

## Summary

About 12M tokens were processed, roughly 87% of them cache reads. The
orchestrator stays small, as designed. The builders use most of the tokens,
but they run on `gpt-6-luna`, the cheap model, so that is acceptable. The
waste worth fixing is elsewhere: the Beads lock fails inside the sandbox,
which pushed one decision up to autopilot at `xhigh`; every MCP server in the
user's Codex config loads into every Codex run (noise and reach, not tokens;
now fixed); one builder run died and was relaunched; and a
docs-only rework triggered a full re-verification.

## Numbers

| Run | Model / effort | Input (cached) | Output (reasoning) | Commands |
| --- | --- | --- | --- | --- |
| builder .1 (one test assertion) | luna xhigh | 2.43M (2.32M) | 27k (17k) | 54 |
| builder .2 (runbook doc) | luna xhigh | 1.19M (1.10M) | 20k (13k) | 18 |
| builder .3, aborted | luna xhigh | none reported | none | 5 |
| builder .3, verify | luna xhigh | 0.73M (0.67M) | 14k (10k) | 19 |
| reviewer-security | astra medium | 0.18M (0.16M) | 1.3k | 5 |
| approver | astra high | 0.26M (0.23M) | 3.2k | 8 |
| autopilot | astra xhigh | 0.66M (0.60M) | 7.9k (1.4k) | 22 |
| builder .4, rework (runbook) | luna xhigh | 2.01M (1.90M) | 51k (33k) | 18 |
| builder .5, verify round 2 | luna xhigh | still running | | 34 so far |
| **Codex total** | | **7.43M (6.98M)** | **125k** | |
| orchestrator | opus | 3.29M (3.21M cache read, 80k cache write) | 15k | 50 calls |
| spec-writer | opus | 0.90M | 12k | 16 calls |
| planner | opus | 0.13M | 4k | 6 calls |
| reviewer-code / ux / ui | sonnet | 0.18M / 0.06M / 0.06M | 2k / 0.3k / 0.6k | 8 / 4 / 4 calls |

## What works

- **The orchestrator stays small.** Its largest tool result was 3.4 KB, the
  autopilot decision. `run-codex` returns one line, and subagents return short
  hand-backs. 50 calls and 15k output tokens for a full spec → build → review →
  approve → autopilot → rework cycle.
- **Prompt caching does most of the work.** 94% of Codex input and 97% of the
  orchestrator's input was cached.
- **Builder spend is acceptable.** Builders took 86% of Codex input. Every
  call re-sends the full context, so a 54-call run reaches 2.4M even at about
  45k tokens per call. On luna this is cheap, so it is a deliberate trade, not
  a defect. Builders also read widely: whole-plane test suites, 55 KB failure
  dumps, broad `rg` sweeps, and a re-read of the job folder on every cold
  start. If the builder ever moves to a pricier model, look here first.

## What to fix

1. **Beads is unreadable inside the Codex sandbox.** Every Codex role tried
   `bd --readonly` and failed to open the shared database lock. The approver
   ESCALATEd, partly because the Beads-closure and merge-tree gates were
   "unverified". That led to an autopilot run at `xhigh` (665k input), and the
   rework builder ended its report by passing the same unresolved gate back.
   The runbook defects behind the escalation were real, but the Beads noise
   added a gate nobody in the sandbox could clear. Fix: give the sandbox read
   access to the Beads directory, or have the orchestrator pass the bead and
   child-task state into the approver and autopilot prompts.
2. **Every MCP server in the user's Codex config loads into every `codex
   exec`.** That is eight servers here, including context7, gmail, Home
   Assistant and playwright. context7's token had expired, so every run logged
   `AuthRequired ... invalid_token`. No role needs any of them. A measured
   one-line call used 15,325 input tokens with or without them, so Codex loads
   their tools on demand and this is **not a token cost**. The cost is startup
   work, stderr noise, and mail and home-automation tools within a builder's
   reach. `-c mcp_servers={}` does not clear them, and neither does a quoted
   key. **Fixed** in `run-codex`: it reads `config.toml` and passes
   `-c mcp_servers.<name>.enabled=false` for each server. Servers that come
   from plugins (here `cua_repl`) are not in `config.toml` and stay on.
3. **A builder run died and was relaunched.** `174931-builder` stopped after
   5 commands without a `turn.completed`, and a fresh run started 23 seconds
   later from a cold start. The cause wasn't found. It's worth having
   `run-codex` record why a run ended (the exit code and the last event type)
   so these can be told apart from real BLOCKED results.
4. **Re-verification ignores what changed.** The rework changed one Markdown
   runbook, yet round-2 verification re-runs the infra test suites. Fix: scope
   the round-N verification task to the rows the rework diff touches. This
   matters more for wall-clock time than for tokens.

## Not a finding

- The approver's ESCALATE and the autopilot's REWORK were correct on the
  merits. The adversarial review's notes named two real runbook defects that
  all five PASS verdicts had missed.
