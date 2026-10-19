# AI Factory

A visual software factory for Claude Code. It runs on Claude and OpenAI models,
tracks work in [Beads](https://github.com/gastownhall/beads), and has an
autopilot that can make the human's decisions. You type `/factory <feature>`
and agents write a spec, break it into Beads tasks, build them one at a time on
their own branch, review the result from five angles, and either merge it to
`main` or hand it to you, or to the autopilot.

Based on [zazencodes' software factory](https://github.com/zazencodes/zazencodes-season-3/tree/main/src/software-factory-claude-code),
with three additions:

1. **Beads for the work, the spec for the truth.** As in
   [Prism](https://github.com/baldaworks/prism), each job is a Beads `feature`
   with `task` children and dependencies, and the queue lives in Beads. The
   spec still defines what "done" means: acceptance criteria live only in
   `spec.md`, and every task points back at the criteria it covers.
2. **Autopilot.** Every point where the factory would stop for a human can go
   to an `autopilot` agent instead. It reads the evidence and picks MERGE,
   REWORK, RESPEC or PARK, within limits set by `factory/autopilot-policy.md`.
3. **Multiple models.** Each role runs on a Claude model (as a subagent) or an
   OpenAI model (through `codex exec`), set in one file.

```
feature ─► spec-writer ─► planner ─► Beads tasks ─► builder, one task at a time
  (bead)     opus          opus           ▲          luna (→ sol on retry)
                                          │                   │
                       CHANGES: file      │   [security, code, ux, ui, adversarial]
                       fix tasks ◄────────┴──  astra  sonnet sonnet sonnet  sol*
                                                              │ all PASS
                                                              ▼
                              merge to main ◄─ APPROVE ─ approver ─ ESCALATE ─► needs-human
                                    ▲                     astra                    │
                                    └──── MERGE ── autopilot ◄── on autopilot ─────┘
                                                    astra
```

## Model routing

`factory/models.json` maps every role to a provider, a model and, for OpenAI
models, a reasoning effort. Edit it to move any role to any model.

| Role                 | Model          | Why                                                        |
| -------------------- | -------------- | ---------------------------------------------------------- |
| `spec-writer`        | opus           | The spec is the contract; it gets the strongest writer      |
| `planner`            | opus           | Breaking the spec into tasks is spec work; the planner gets the same strong model as the spec-writer |
| `builder`            | gpt-6-luna     | The grunt: small, well-specified tasks, at `xhigh` effort   |
| `builder-escalation` | gpt-6.1-sol    | A task's second try after BLOCKED, and last-round fixes     |
| `reviewer-security`  | gpt-6-astra    | Heavy reasoning where a miss is expensive                   |
| `reviewer-code`      | sonnet         | A Claude model reviews OpenAI-written code                  |
| `reviewer-ux`        | sonnet         | Drives the browser; runs as a Claude subagent outside the Codex sandbox |
| `reviewer-ui`        | sonnet         | Same                                                        |
| `reviewer-adversarial` | gpt-6.1-sol* | The Codex plugin's `adversarial-review`: tries to break the branch against its spec |
| `approver`           | gpt-6-astra    | The big decision: merge without a human?                    |
| `autopilot`          | gpt-6-astra    | Stands in for the human, at `xhigh` effort                  |

The rule of thumb: code is checked by both providers. Luna writes it; Astra,
Sol and Sonnet review it.

\* `reviewer-adversarial` runs through the installed
[Codex plugin](https://github.com/openai/codex-plugin-cc)
(`factory/bin/run-adversarial`), not a role file. It reviews read-only and
returns structured findings with a severity and a confidence. Findings at a
severity in `block_on` (default critical and high) with confidence of at least
`min_confidence` (default 0.6) make the verdict CHANGES; the rest are Notes.
Both settings are in `models.json`.

Claude roles run through one thin subagent, `.claude/agents/factory-agent.md`,
with the model passed per spawn. OpenAI roles run through
`factory/bin/run-codex`, which reads the same role file, runs `codex exec` in
the job's worktree with write access to the job folder only, and logs
everything to `factory/jobs/<job-id>/.runs/`. The Codex sandbox keeps `.git`
read-only, so no agent commits: builders list their files and a commit message,
and the orchestrator commits each task as one commit tagged with its bead id
(`Add limiter middleware (app-k2f.1)`). Both read the same
`factory/agents/<role>.md`, so moving a role between providers is a one-line
change.

## Beads

| Beads                                  | Factory                                |
| -------------------------------------- | -------------------------------------- |
| `feature` bead, label `factory`        | one job; `--spec-id` points at its spec |
| `task` children with dependencies      | the plan; built in dependency order    |
| `task` labelled `fix`                  | a review, rework or autopilot follow-up |
| `task` labelled `final`                | "verify all acceptance criteria"       |
| label `queued`                         | the backlog for `/factory next` and autopilot |
| label `needs-human`                    | parked for you                         |

Agents only read Beads (`bd --readonly`). The orchestrator makes every write
from the main checkout, so the Codex sandbox and parallel sessions never
collide. Queue claims use `bd ready --claim`, which is atomic.

## Brownfield: an existing repo, Beads and a PRD

The factory shares Beads with people and other tools. It never edits, claims,
closes or relabels a bead that someone else is working on, never touches
labels other than its own, and never deletes a bead.

```
/factory import docs/prd.md       map the PRD onto existing beads, queue what's new
/factory adopt app-40             run a job from an existing bead (keeps its child tasks)
/factory adopt app-7              an epic: queue its open, unassigned children
```

`/factory import` runs an `importer` (Opus) that reads the PRD, every open and
closed bead, and the code, then sorts each PRD deliverable into:

| Action     | Meaning                                         | What the factory does                     |
| ---------- | ----------------------------------------------- | ----------------------------------------- |
| `done`     | a closed bead or the code already delivers it   | nothing                                   |
| `owned`    | an open bead covers it and someone is on it     | nothing; new work depends on it           |
| `adopt`    | an open, unassigned bead covers it              | labels it `factory,queued`, comments PRD detail |
| `create`   | nothing covers it                               | new `feature` bead, queued, PRD section in its description |
| `conflict` | a bead or the code contradicts the PRD          | comments both sides, labels `needs-human` |

You see the mapping and approve it before anything is written
(`/factory autopilot import` skips the question). Then `/factory next` or
`/factory autopilot` works the queue. Dependencies on in-flight beads hold a
job back until that work closes, so the factory never builds ahead of your
team. The spec-writer treats the PRD section as upstream of its spec, and the
planner reuses an adopted bead's existing child tasks where they fit.

## Autopilot

```
/factory autopilot                drain the queue with no human in the loop
/factory autopilot 3              stop after three jobs
/factory autopilot <feature>      one new job on autopilot
/factory autopilot <job-id>       hand a parked job to the autopilot
```

When a job hits a plan BLOCKED, a build BLOCKED (after escalating to Sol), run
out of review rounds, an approver ESCALATE or a failed merge, the autopilot
reads everything about the job, re-runs the checks it needs, and writes
`autopilot-<k>.md`:

- **MERGE**: accept the escalation and merge. Only with an all-PASS final
  round, a clean `merge-tree`, and high or medium confidence.
- **REWORK**: exact instructions, filed as a fix task for the builder.
- **RESPEC**: amendments for the spec-writer; the job is planned again.
- **PARK**: leave it for a human, saying exactly what they need to decide.

`factory/autopilot-policy.md` lists what the autopilot must always park
(secrets, production data, payments, auth, CI and deploy config, and more) and
what it may decide alone. The orchestrator enforces the hard limits: at most
two REWORKs and one RESPEC per job, never push.

## Commands

```
/factory <feature>               run a new job through the loop
/factory add <feature> [P0-P4]   queue a feature in Beads
/factory next                    run the highest-priority queued feature
/factory autopilot [...]         see above
/factory import <prd>            map a PRD onto existing beads and queue the gaps
/factory adopt <bead>            run a job from an existing bead (or queue an epic's children)
/factory status                  queue, running and parked jobs
/factory approve <job-id>        merge a needs-human job into main
/factory rework <job-id> <note>  send a needs-human job back to the builder
```

## Layout

```
.claude/
  skills/factory/SKILL.md        the orchestrator: runs the loop, writes job.json and Beads
  agents/factory-agent.md        runs any role on a Claude model
factory/
  models.json                    role → provider, model, effort
  autopilot-policy.md            what the autopilot may decide alone
  agents/                        one instruction file per role, for any provider
    spec-writer.md  planner.md  builder.md
    reviewer-security.md  reviewer-code.md  reviewer-ux.md  reviewer-ui.md
    approver.md  autopilot.md  importer.md
  bin/run-codex                  runs an OpenAI role through codex exec
  bin/run-adversarial            runs the Codex plugin's adversarial review as a reviewer
  dashboard.html                 the visual board
  jobs/                          one folder per job (runtime state)
  imports/                       one folder per PRD import (runtime state)
```

## Use it in your repo

1. Install `bd` (Beads), the Codex CLI (logged in, with access to the models in
   `models.json`), the Codex plugin for Claude Code (for the adversarial
   reviewer), `node` and `jq`. Install
   [`agent-browser`](https://github.com/vercel-labs/agent-browser) if your
   project has pages to look at.
2. Copy `.claude/` and `factory/` into your repo root.
3. Run `bd init` in the repo if it has no Beads workspace yet. If it has one,
   keep it: see **Brownfield** above, and start with `/factory import <prd>`.
4. Add `/factory/jobs/` and `/factory/imports/` to your `.gitignore`. They
   are runtime state.
5. Make sure your `AGENTS.md` (or `CLAUDE.md`) says how to set up a fresh
   checkout, start the dev server on a given port, and run your tests, build
   and lint. The agents carry nothing repo-specific.
6. Read `factory/autopilot-policy.md` and adjust it before using autopilot.
7. Commit everything on `main`, then run `/factory <feature>`.

## Dashboard

```bash
cd factory && python3 -m http.server
```

Open <http://localhost:8000/dashboard.html>. Jobs move across eight stages as
cards. Each card shows its bead, a strip of task dots that fill in as Beads
tasks close, and review chips per round. Column headers show the models from
`models.json`. Autopilot jobs are flagged, and jobs that need you stand out.
Click a card to read the spec, plan, task reports, reviews and autopilot
decisions.
