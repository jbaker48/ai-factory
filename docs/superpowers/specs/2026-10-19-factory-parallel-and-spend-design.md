# Factory: parallel jobs and spend visibility

- Date: 2026-10-19
- Status: ready for review by the user
- Inputs: the factory as installed and changed in `~/Development/garmin-ai-coach`
  (commits `c16ca673`, `94450b8b`, `f216500a`), and
  `docs/findings/2026-10-19-token-efficiency-first-run.md`

## Why

The factory ran its first autopilot job in garmin-ai-coach. Three things came
out of that:

1. Changes made there are worth having in ai-factory itself: landing through
   PRs, diffing against `origin/main`, and a priority order for the queue.
2. Spend is invisible while autopilot drains. The token table in the findings
   doc was built by hand from logs and transcripts. The user wants to watch it
   live to spot runaway jobs, compare models per role, and see where spend
   blows out.
3. Jobs run one at a time, though nothing in the design needs that. Each job
   already has its own worktree, job folder, ports and branch.

Both plans are flat-rate subscriptions: Claude on a Max plan, Codex on a
ChatGPT plan. Dollars are not the meter. What runs out is plan quota (5-hour
and weekly windows). Tokens are the detail under it.

## Goals

- Port the garmin-ai-coach factory changes into ai-factory, made generic.
- Fix findings 1–3 from the findings doc.
- Record every agent run's usage and show live spend per job, stage, role and
  model, plus plan-quota meters, on the dashboard and in `/factory status`.
- Run several jobs at once from `factory/bin/autopilot`.

## Non-goals

- Spend never drives a decision. No pausing, parking, killing, throttling or
  model switching based on usage. Visibility only (user's decision).
- No coordination between parallel jobs: no overlap detection, no scheduling
  around shared files. Jobs stay isolated in worktrees and land through their
  own PRs, the way two developers would (user's decision).
- Findings fix 4 (scope re-verification to the rework diff) is out of scope.
- Dollar figures are not a goal. `total_cost_usd` from `claude -p` may be
  shown as "API-equivalent" but nothing is built around it.

## Anti-goals

- The orchestrator's context grows. The findings doc shows it staying small
  (largest tool result 3.4 KB); usage collection must not route big logs
  through it. Scripts write usage files; the orchestrator never reads
  transcripts.
- A run-of-the-mill target repo breaks: one with no required checks, no
  GitHub remote, or no `lane:*` labels.
- Parallel autopilot that corrupts Beads or double-runs a bead.
- Default behaviour changes for someone who doesn't opt in: `--jobs` defaults
  to 1.

## Part 1 — Port garmin-ai-coach changes and findings fixes

Port from garmin-ai-coach, which is the reference implementation:
`factory/bin/pr-land`, `factory/bin/next-bead`, and the edits to
`.claude/skills/factory/SKILL.md`, the role files, `autopilot-policy.md` and
`factory/bin/autopilot` in `94450b8b` and `f216500a`. Also update
`AGENTS.template.md` with the rule "never commit or push to main directly",
and `INSTALL.md` / `README.md` where they describe merging.

### 1a. Land through a PR (`pr-land`)

Adopt as written, with these changes:

- **No required checks.** When the base branch has no required checks, `gh pr
  checks --required` never reports any. Today the script waits ~10 minutes and
  then `--watch` fails. Instead: after the registration wait, if there are no
  required checks, watch all checks; if there are no checks at all, merge
  straight away.
- **Base moved since review: re-review, don't just re-test (user's
  decision).** See "Landing on a moved base" below; it applies to both land
  modes.
- **Repos without GitHub (user's decision: needed).** A setting
  `land: "pr" | "local"` (default `pr`). See "Local land mode" below.
- Drop the garmin-specific "drafts skip CI in this repo" comment; keep opening
  non-draft PRs.
- `autopilot-policy.md` says the autopilot never pushes. Keep that, and add
  that only the orchestrator's **Merge** step pushes, and only the job branch.

### Landing on a moved base

The approver must have seen the code that lands. When a job is approved, the
orchestrator records the base commit its final review round diffed against
(`reviewed_base` in `job.json`, set at the start of each review round). Just
before landing (in `pr-land` after pushing and before merging, and in local
mode before `git merge`), if the base has moved past `reviewed_base`:

- If the branch merges cleanly with the new base, merge the base into the job
  branch in the worktree (a merge commit, no rebase), and send the job to a
  new **Review round N+1** and then the approver again. It counts against
  `MAX_ROUNDS`; exhausting it is `rounds-exhausted` as today. The PR stays
  open and is reused.
- If it conflicts: `merge-blocked`, as today.

`pr-land` signals this with a new exit code (e.g. 6, "base moved, branch
updated, re-review needed"), and the skill's **Merge** routes it back to
review. Between the check and the merge, GitHub's own "require up to date"
protection (when set) or a re-check right before `gh pr merge` closes the
window; the builder picks which, but the rule holds: nothing lands on a base
its final review didn't see. Conflicts are expected to be rare, so the extra
review round is an accepted cost.

### Local land mode (`land: "local"`)

For repos with no GitHub remote (no remote at all, or a non-GitHub one).

- **Base ref.** `pr` mode uses `origin/main`; `local` mode uses local `main`
  and never fetches or pushes. The ref is no longer a literal in role files:
  the orchestrator adds `Base: <ref>.` to every role prompt (the standard
  prompt line in SKILL.md), and role files, `run-adversarial`, the resume
  checks and the merge-tree checks use `<base>`.
- **Merge.** The original in-checkout `git merge --no-ff factory/<job-id>`
  path from ai-factory's SKILL.md, with its precondition (main checkout clean
  outside `factory/` and on `main`; otherwise `merge-blocked`). Never pushes.
- **AGENTS rule.** "Never commit or push to main directly" stays, with the
  exception spelled out: in local mode, the factory's **Merge** step is the
  only thing that commits to `main`.
- **Parallel jobs.** Supported. Merges into the main checkout are serialised
  with a lock (e.g. `flock` on a file under `factory/`), and the moved-base
  rule above applies, since `main` moves when another job merges.
- `/factory status` and the dashboard show which mode the repo is in.

### 1b. `origin/main` as the base

Adopt for `pr` mode: worktrees branch from the base after a fetch, and every
role diffs against it, passed as `Base:` (above).

### 1c. Queue order (`next-bead`)

Adopt the mechanism, not garmin's defaults. Priority labels come from a new
settings file (below), default empty, so the order is plain priority then
age. `FACTORY_PRIORITY_LABELS` still overrides. Remove the `docs/alpha-path.md`
and `lane:*` references from the skill text; say "beads carrying a priority
label from `factory/settings.json`".

### Settings file

New `factory/settings.json`, read by scripts with `jq`, every key optional:

```json
{ "land": "pr", "priority_labels": [] }
```

`models.json` stays per-role only. Part 3 adds `jobs` here.

### 1d. Findings fix 1 — Beads state in prompts

Codex roles cannot open the Beads lock from inside the sandbox, which made the
approver escalate on gates it couldn't verify. The orchestrator already runs
`bd` outside the sandbox. Before spawning the approver, autopilot, and any
other Codex role whose role file reads Beads, the orchestrator writes the
state it needs to `<job folder>/beads.md` (the bead, `bd show`, `bd children`
with status) and the role files read that file instead of calling
`bd --readonly`. Claude-side roles may keep `bd --readonly` (they're not
sandboxed) but switching them too is fine and simpler. This also cuts Beads
lock contention in part 3.

### 1e. Findings fix 2 — no MCP servers in Codex runs

`run-codex` passes `-c mcp_servers={}` (or the equivalent that empties the
user's configured servers; verify against the installed `codex` CLI). No role
needs MCP. Same for `run-adversarial` if it launches Codex with the user's
config.

### 1f. Findings fix 3 — record how a run ended

`run-codex` (and `run-adversarial`) record, per run, the exit code and the
type of the last JSON event, so a run that dies without `turn.completed` is
distinguishable from a BLOCKED result. This is written into the usage record
in part 2 (`ended` field), and `run-codex`'s one-line output says
`ended: <...>` when it isn't a normal completion.

## Part 2 — Spend and quota visibility

### What gets recorded

One JSON line per agent run, appended to `<job folder>/usage.jsonl`:

```json
{"ts":"2026-10-19T17:37:47+11:00","role":"builder","provider":"openai",
 "model":"gpt-6-luna","effort":"xhigh","stage":"build","round":0,
 "task":"<task-id or null>","input":2431660,"cached":2323840,"cache_write":0,
 "output":26874,"reasoning":16590,"duration_s":482,"exit":0,
 "ended":"turn.completed","quota":{"window":"weekly","before":31.0,"after":32.0},
 "log":".runs/20261019-173747-builder"}
```

Fields that a source can't supply are `null`, never guessed.

Sources:

- **Codex roles (`run-codex`, `run-adversarial`).** Tokens: sum of
  `turn.completed.usage` across the run's `.jsonl` (a run may have several
  turns). Quota: the `thread.started` event gives the thread id; the matching
  rollout under `~/.codex/sessions/**/rollout-*-<thread id>.jsonl` carries
  `rate_limits` (`primary`/`secondary` with `used_percent`, `window_minutes`,
  `resets_at`, `plan_type`). Record the first and last value seen in the run.
  Verified present on 2026-10-19 (`plan_type: "prolite"`, weekly window).
- **Claude subagents (`factory-agent`).** Their transcripts are at
  `~/.claude/projects/<project slug>/<session id>/subagents/agent-*.jsonl`;
  the first user message starts `Role: factory/agents/<role>.md. Job folder:
  <path>`, which attributes the run to a job and role. Sum `message.usage`
  over assistant messages, de-duplicated by message id (streamed messages
  repeat). The orchestrator calls a small script after each subagent returns
  (Claude's call: no hooks, so installing stays a plain copy and touches none
  of the user's Claude Code config). The script, not the orchestrator, reads
  the transcript, and it prints at most one line.
- **The orchestrator itself.** Its own session transcript, attributed to the
  job it ran. Recorded with `role: "orchestrator"` when the session ends
  (headless: `factory/bin/autopilot` has the session id from `claude -p` JSON
  output and records it after each session). Interactive orchestrator usage
  is recorded by the orchestrator calling the same script at the job's end
  states (merged, needs-human); it may lag until then.
- **Claude plan quota: not recorded (Claude's call).** Claude Code tracks
  `five_hour` / `seven_day` limits, but the only script-readable route found
  is the status-line input, which reaches only a configured status-line
  command in interactive sessions, not headless autopilot, the main use case.
  Claude ships tokens-only, and the dashboard says so. Revisit if Claude Code
  exposes plan usage to `claude -p` output or a documented command. Don't
  scrape undocumented endpoints.

A shared script (e.g. `factory/bin/usage-record`) does the parsing so
`run-codex`, the hook and `autopilot` don't each reimplement it. It must not
fail a run: if parsing breaks, it writes a line with nulls and the error.

### Attribution caveat

Quota `before/after` is the account-wide meter. With parallel jobs, or the
user working in other sessions, the delta overlaps other work. The dashboard
shows quota as a window-level meter (current % per window, reset time) and
per-run deltas only as a rough indicator, labelled as such. Tokens are the
per-run truth.

### Where it shows

- **`factory/dashboard.html`** (already polls each `jobs/<id>/job.json`) also
  reads each job's `usage.jsonl` and shows:
  - Quota meters per plan and window: Codex (weekly, and 5-hour if present),
    Claude (if available), current %, time to reset, as of the latest record.
  - Per job: total tokens (input/cached/output), number of runs, a split by
    stage, and a flag when the job is well above the median of finished jobs
    at the same stage. Builder's call on "well above" (e.g. 2× median, needs
    ≥3 finished jobs before flagging), shown as a flag, nothing more.
  - Across jobs: totals per role and per model, and per role average per job,
    for comparing models.
- **`/factory status`** prints one line per active job with its token total
  and runs, plus the quota meters. Computed by a script, not by the
  orchestrator reading usage files.
- **`factory/bin/autopilot`'s** per-job summary line reports tokens instead of
  (or as well as) `$` — the `$` figure is API-equivalent and should be
  labelled so.

## Part 3 — Parallel autopilot

`factory/bin/autopilot [<count>] [--jobs N] [--budget <usd>]`. `N` defaults
to `settings.json`'s `jobs`, else 1. With `N = 1` behaviour is today's.

- **Workers.** Up to N jobs in flight. Each worker runs today's per-job loop
  (adopt session, then up to `MAX_RESUMES` resumes) and logs to its own files
  in `factory/autopilot-runs/`. `<count>` is total jobs across workers. Output
  lines are prefixed with the job so interleaving stays readable. Ctrl-C stops
  every worker and prints the jobs that were in flight with their
  `/factory resume` commands.
- **Claim before launch.** Today the script picks a bead and the session
  claims it. With several workers two could pick the same bead. The script
  claims it (`bd update <bead> --claim`) before launching the session; on
  failure it asks `next-bead` again. A plain assignee check can't tell the
  script's claim from the user's own (same identity), so the script marks its
  claim: it runs `bd` with a distinct actor (`BD_ACTOR=factory-autopilot`, or
  whatever `bd` uses for the actor/assignee; verify) and the prompt says
  `Claimed for you by autopilot as <actor>.` The adopt path accepts an
  in-progress bead only when its assignee is that actor; any other
  in-progress bead is still refused (brownfield rule). Claude's call.
- **Find the job by bead.** Today the script finds the job with
  `select(.bead == $b)` over every `job.json`, which is fine, but must not
  pick up another worker's job; keep it keyed on bead.
- **A worker failing** (session made no job, resumes exhausted) stops that
  worker's job, not the others. The script exits non-zero at the end if any
  worker failed.
- **Already parallel-safe, keep it so:** job ids via atomic `mkdir`, ports and
  agent-browser sessions from the job number, per-job worktrees and
  `job.json`, `pr-land` never touching the main checkout.

### Beads under concurrency — verify first

Several orchestrators writing Beads at once is the likeliest failure.
Before building the worker pool, write a stress test (script, kept in the repo)
that runs N concurrent processes doing the factory's write pattern (claim,
label, comment, create child tasks, close) against a scratch Beads database
and checks for lock errors and lost writes. It is a hard gate: the worker
pool isn't built until it passes, with or without the wrapper. If it fails, wrap the factory's
`bd` writes in a lock (e.g. `flock` on a file under `.beads/`) via a small
`factory/bin/bd-write` wrapper, and use it in the skill. 1d removes the
sandboxed readers from the picture.

## Constraints

- Shell scripts stay bash + `jq` + `gh`, matching `factory/bin/*`.
- The orchestrator's context stays small: scripts print one line; files hold
  detail.
- garmin-ai-coach is the first consumer. After this lands, re-installing there
  should be a straight copy plus a `settings.json` with its `lane:*` labels.

## Decided by the user

- Adopt `pr-land`, `origin/main`, and `next-bead` (mechanism, not defaults).
- Spend: watched live during autopilot; for runaway jobs, model choice, and
  blowouts; visibility only, nothing acts on it.
- Both providers are flat-rate plans, so quota is the meter.
- Parallelism means several jobs at once, isolated by worktree and PR, no
  coordination between them.
- A job whose base moved after approval gets re-reviewed before landing, not
  just re-tested.
- Local land mode for repos without GitHub is needed.

## Claude's calls (check these)

- Moved base detected by a `reviewed_base` sha; the update is a merge commit,
  not a rebase; the extra review round counts against `MAX_ROUNDS`.
- Local mode serialises merges with a lock and supports parallel jobs.
- `factory/settings.json` as a new file rather than extending `models.json`.
- Beads state passed as `beads.md` in the job folder, for Codex roles at least.
- Findings fix 3 folded into the usage record.
- Usage stored per job as `usage.jsonl`; quota deltas labelled approximate.
- Claude usage collected by the orchestrator calling a script, no hooks.
- No Claude plan quota for now (status line can't reach headless runs).
- Autopilot claims with a distinct Beads actor so adopt can tell its claims
  from the user's.
- `--jobs` defaults to 1; a Beads stress test gates part 3.

## Left to the builder

- The runaway threshold and dashboard layout.
- Whether `main` becomes a setting.
- Exact `codex` flag to empty MCP servers, verified against the installed CLI.
