# AI Factory

A visual software factory for Claude Code. It runs on Claude and OpenAI models,
tracks work in [Beads](https://github.com/gastownhall/beads), and has an
autopilot that can make the human's decisions. You type `/factory <feature>`
and agents write a spec, break it into Beads tasks, build them one at a time on
their own branch, review the result from five angles, and either merge it to
`main` or hand it to you, or to the autopilot.

Three ideas shape it:

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
models, a reasoning effort. Edit it to move any role to any model, or pick
a preset from `factory/presets/` to match the subscriptions you have:

```bash
factory/bin/models          # print the active preset: mixed, lean, claude, openai or custom
factory/bin/models mixed    # Claude and OpenAI (Codex) models, the default
factory/bin/models lean     # mixed, spending less quota
factory/bin/models claude   # Claude models only
factory/bin/models openai   # OpenAI models only, through the Codex CLI
```

- **`lean`** is `mixed` with less thinking where the output is long and the
  judgement is not. Reasoning counts as output, so the builder (the role that
  writes the most) drops from `xhigh` to `high` effort, and the escalation
  builder catches the tasks that turn out hard. Autopilot drops to `high` too.
  The importer and briefer, which turn files into beads or summaries, move from
  Opus to Sonnet. The spec-writer and planner stay on Opus: their output is
  short and every later stage follows it.
- **`claude`** runs every role as a Claude subagent: Sonnet builds and
  reviews, Opus takes the spec, plan, escalation, security, adversarial,
  approver and autopilot roles. It needs neither the Codex CLI nor the Codex
  plugin.
- **`openai`** runs every role through `codex exec`: Luna builds, Sol writes
  the spec and plan and takes the escalation and adversarial review, Astra
  reviews and decides. It needs no Claude subagents and no Codex plugin. Chrome
  can't start inside the Codex sandbox, so for the UX and UI reviewers
  (`"browser": true`) `run-codex` starts their agent-browser session outside
  it and the reviewer drives that.
- In both, the adversarial reviewer runs from
  `factory/agents/reviewer-adversarial.md` instead of the Codex plugin.

The orchestrator is still a Claude Code session (`/factory` and
`factory/bin/autopilot`), whatever the preset, so `openai` moves the role work
to your ChatGPT plan but still needs Claude Code to drive it. A `models.json`
you've edited by hand counts as `custom`, and switching away from it needs
`--force`. The switch applies from the next role the orchestrator runs. The
table below is the `mixed` preset.

| Role                 | Model          | Why                                                        |
| -------------------- | -------------- | ---------------------------------------------------------- |
| `spec-writer`        | opus           | The spec is the contract; it gets the strongest writer      |
| `planner`            | opus           | Breaking the spec into tasks is spec work; the planner gets the same strong model as the spec-writer |
| `builder`            | gpt-6-luna     | The grunt: small, well-specified tasks, at `xhigh` effort   |
| `builder-escalation` | gpt-6.1-sol    | A task's second try after BLOCKED, and last-round fixes     |
| `reviewer-security`  | gpt-6-astra    | Heavy reasoning where a miss is expensive                   |
| `reviewer-code`      | sonnet         | A Claude model reviews OpenAI-written code                  |
| `reviewer-ux`        | sonnet         | Drives the browser, which a Claude subagent can start itself |
| `reviewer-ui`        | sonnet         | Same                                                        |
| `reviewer-adversarial` | gpt-6.1-sol* | The Codex plugin's `adversarial-review`: tries to break the branch against its spec |
| `approver`           | gpt-6-astra    | The big decision: merge without a human?                    |
| `autopilot`          | gpt-6-astra    | Stands in for the human, at `xhigh` effort                  |
| `briefer`            | opus           | Briefs you on a parked job in `/factory review` and writes up your decision |

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
collide. Queue claims use `bd update <bead> --claim`, which is atomic; the
autopilot drain claims with a compare-and-set (`--if-assignee ''`) so that
two of its workers, which share one actor, can't both take a bead.

Every role gets a base ref in its prompt (`Base: <base>.`) and diffs against
that, not a literal `main`. `factory/settings.json` sets it: `origin/main` with
`land: "pr"` (the default), `main` with `land: "local"`.

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

For a long drain, run the queue from your shell instead:

```bash
factory/bin/autopilot              # drain the queue, one headless session per job
factory/bin/autopilot 3 --budget 20   # three jobs, at most $20 per session
factory/bin/autopilot --jobs 3     # run up to three jobs at once
```

`/factory autopilot` runs every job in one session, so the orchestrator's
context keeps growing. `factory/bin/autopilot` starts a new `claude -p`
session for each job, so every job starts clean. If a session ends before its
job merges or parks (a crash, the budget cap, a time limit), the script runs
`/factory resume <job-id>` in a new session, up to twice. It prints each job's
outcome, cost and session id (`claude --resume <id>` opens the session) and
keeps the session output in `factory/autopilot-runs/`. It runs sessions with
`bypassPermissions`, because nobody is there to answer prompts (set
`FACTORY_PERMISSION_MODE` to change that), and raises the 10-minute limit
headless sessions put on background commands, which long Codex runs would hit.
Run one driver per repo.

`--jobs N` runs up to N jobs at once, each in its own session and worktree
(default: `"jobs"` in `factory/settings.json`, else 1). `<count>` counts jobs
across all of them, and every output line starts with `[<job-id>]`. The
script claims each bead before its session starts, as the Beads actor
`factory-autopilot`, so two workers never take the same bead; `/factory
adopt` accepts a bead claimed that way and still refuses any other in-progress
bead. Ctrl-C stops every session and prints the jobs that were in flight with
their `/factory resume` commands. A failed job stops its own worker, not the
others, and the script exits 1 at the end.

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
/factory status                  queue, running, parked and resubmitted jobs
/factory review [<job-id>]       decide parked jobs with a brief, then resubmit them
/factory approve <job-id>        resubmit a needs-human job to be merged
/factory rework <job-id> <note>  resubmit a needs-human job to the builder with a note
/factory resume <job-id>         pick up a job whose session ended mid-step
/factory retro <job-id>          run a retro on one job by hand
```

## Human review

Parked jobs wait for you at `needs-human`. `/factory review` works through
them oldest first. For each job a `briefer` agent reads everything about it
and writes `human-brief-<k>.md`: the situation with file:line evidence, one to
three decisions only you can make (each with options and a recommendation),
and out-of-scope problems as proposed beads. The session asks you those
questions, the briefer writes your answers up as `human-<k>.md` (APPROVE,
REWORK, RESPEC or DROP), the session files the beads you chose, and the job
is resubmitted. The review session never builds or merges anything: the
autopilot drain picks resubmitted jobs up before new beads, and the session
offers to start `factory/bin/autopilot --watch` if none is running. Your
decisions bind every later role: the builder, planner, spec-writer, approver
and autopilot all work within the scope and "do not change" lines you set,
and they don't count toward the autopilot's rework and respec limits. A
dropped job closes its PR and bead and ends at `dropped`. `/factory review`
also clears import conflicts labelled `needs-human` by asking you about each.

## Retros

When a job that needed extra attempts (more than one review round, a rework
or respec, a builder rerun, an escalation, or an autopilot or owner
decision) merges or is dropped, the orchestrator runs a `retro` agent on it,
headless drains included. It works out what each extra attempt was for, writes `retro.md`,
and drafts the fixes that would have saved them:

- **Repo lessons** go into `AGENTS.md` in a PR labelled `factory-retro`,
  titled `Retro <job-id>: <n> lessons` (with `land: "local"`, a kept branch
  `factory/retro-<job-id>` instead).
- **Factory fixes**, such as changes to role files, `SKILL.md` or scripts,
  go to ai-factory itself when `factory_source` in `factory/settings.json`
  names a local ai-factory checkout: a PR there titled `Retro <repo> <job-id>: <n> fixes`. Without it
  they land in the job folder as `retro-factory.patch`.

Nothing merges by itself; you review the PRs. `/factory retro <job-id>` runs
one by hand on any job, and running it again updates the open PRs.
`/factory status` prints a trend line over the last 10 merged jobs
(first-pass rate, median rounds, reworks and tokens), so you can see whether
the retros help.

## Layout

```
.claude/
  skills/factory/SKILL.md        the orchestrator: runs the loop, writes job.json and Beads
  agents/factory-agent.md        runs any role on a Claude model
factory/
  models.json                    role → provider, model, effort
  presets/                       mixed.json, lean.json, claude.json, openai.json: models.json presets
  autopilot-policy.md            what the autopilot may decide alone
  AGENTS.template.md             starting point for your repo's AGENTS.md
  agents/                        one instruction file per role, for any provider
    spec-writer.md  planner.md  builder.md
    reviewer-security.md  reviewer-code.md  reviewer-ux.md  reviewer-ui.md
    reviewer-adversarial.md      (claude and openai presets)
    approver.md  autopilot.md  importer.md  briefer.md  retro.md
  manifest                       which files an install ships, which the user owns
  bin/install                    installs or upgrades the factory in a repo
  bin/models                     shows or switches the models.json preset
  bin/run-codex                  runs an OpenAI role through codex exec
  bin/run-adversarial            runs the Codex plugin's adversarial review as a reviewer
  bin/prompt-record              records a Claude role's prompt
  bin/job-set                    updates a job.json field with jq, quietly
  bin/jev                        TypeSafe client for Jev, the decision helper
  bin/jev-decide                 Jev's route, reviewers and triage decisions
  jev/                           Jev's question templates and park-paths.txt
  bin/dashboard                  serves dashboard.html and the job files, read-only
  bin/autopilot                  drains the queue, one headless session per job
  bin/retro-due, retro-prep, retro-publish   decide, set up and publish a retro
  dashboard.html                 the visual board, served by bin/dashboard
  dashboard/runs.js              reads run prompt and usage data
  dashboard/git.js               reads job task commits and diffs
  dashboard/detail.js            renders job detail data
  VERSION                        in an installed repo: the ai-factory commit it came from
  jobs/                          one folder per job (runtime state)
  imports/                       one folder per PRD import (runtime state)
  autopilot-runs/                headless session output from bin/autopilot
```

## Use it in your repo

To have a coding agent do this, point it at [`INSTALL.md`](INSTALL.md): it
checks the tools, copies the files, writes and tests `AGENTS.md`, and asks you
the decisions. By hand:

1. Install `bd` (Beads), the Codex CLI (logged in, with access to the models in
   `models.json`), the Codex plugin for Claude Code (for the adversarial
   reviewer), `node` and `jq`. With `factory/bin/models claude` you can skip
   the Codex CLI and plugin; with `factory/bin/models openai`, the plugin. Install
   [`agent-browser`](https://github.com/vercel-labs/agent-browser) if your
   project has pages to look at.
2. Run `factory/bin/install <your repo>` from this checkout. It copies the
   files `factory/manifest` lists as shipped, keeps your `models.json` and
   `autopilot-policy.md` if you have them, adds the `.gitignore` lines, and
   writes `factory/VERSION` (the commit it installed from).
3. Run `bd init` in the repo if it has no Beads workspace yet. If it has one,
   keep it: see **Brownfield** above, and start with `/factory import <prd>`.
4. Write your `AGENTS.md` from this checkout's `factory/AGENTS.template.md`
   (the install leaves it here), and make
   `CLAUDE.md` the one line `@AGENTS.md`. The agents carry nothing
   repo-specific: they get setup for a fresh worktree, the dev server on a
   given port, validation commands and conventions from this file. The
   template's header comment lists the conditions those commands must work
   under (no gitignored files, parallel jobs, no network for reviewers).
5. Read `factory/autopilot-policy.md` and adjust it before using autopilot.
6. Commit everything on `main`, then run `/factory <feature>`.

## Dashboard

```bash
factory/bin/dashboard            # or --port <n>; needs only node
```

Open <http://127.0.0.1:4100/>. The server is read-only and listens on this
machine only; the page polls it every two seconds. Jobs that need you come
first, with their situation and the commands to copy. Running jobs sit on one
stage track (Spec, Plan, Build, Review, Approve) whose legend shows each
stage's models from `models.json`; task dots fill in under Build as Beads
tasks close, and review chips per round sit under Review. Merged and dropped
jobs are listed below. Click a job to read the spec, plan, task reports,
reviews and autopilot decisions. Light and dark follow your OS, with a toggle.
