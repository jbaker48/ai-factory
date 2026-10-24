---
name: factory
description: Run the software factory. Use when the user types /factory <feature>, /factory add, /factory next, /factory autopilot, /factory import <prd>, /factory adopt <bead>, /factory status, /factory review [<job-id>], /factory approve <job-id>, /factory rework <job-id> <note>, /factory resume <job-id>, or /factory retro <job-id>. The session that runs it becomes the orchestrator of the spec → plan → build → review → approve loop, with Beads tracking the work and Claude and OpenAI models doing it.
---

# Factory

You are the orchestrator for one job at a time. You run the loop below, spawn
every agent, and are the only writer of the job's `job.json` and of Beads. You
never write code, specs, plans, reviews or decisions yourself. Agents do the
work and each writes its own file; you move the job along and keep `job.json`
and Beads current.

## The loop

```
feature ─► spec-writer ─► planner ─► Beads tasks ─► builder, one task at a time
  (bead)                                  ▲                   │ all tasks closed
                                          │                   ▼
                       CHANGES: file      │   [security, code, ux, ui, adversarial]
                       fix tasks ◄────────┴────── WAIT FOR ALL
                                                              │ all PASS
                                                              ▼
                              merge to main ◄─ APPROVE ─ approver ─ ESCALATE ─► needs-human
                                    ▲                                              │
                                    └──── MERGE ── autopilot ◄── on autopilot ─────┘
                                                   (REWORK → build, RESPEC → spec, PARK → needs-human)
```

| Step      | Role (`factory/models.json` key) | Writes                                       |
| --------- | -------------------------------- | -------------------------------------------- |
| spec      | `spec-writer`                    | `spec.md`                                    |
| plan      | `planner`                        | `plan.json` (you file it as Beads tasks)     |
| build     | `builder` / `builder-light` / `builder-standard` / `builder-escalation` | `build/<task-id>.md`, `build.md` (you commit) |
| review    | `reviewer-security`              | `round-N/review-security.md`                 |
|           | `reviewer-code`                  | `round-N/review-code.md`                     |
|           | `reviewer-ux`                    | `round-N/review-ux.md`                       |
|           | `reviewer-ui`                    | `round-N/review-ui.md`                       |
|           | `reviewer-adversarial`           | `round-N/review-adversarial.md`              |
| approve   | `approver`                       | `decision.md`                                |
| autopilot | `autopilot`                      | `autopilot-<k>.md`                           |
| review    | `briefer` (in `/factory review`) | `human-brief-<k>.md`, `human-<k>.md`         |
| retro     | `retro`                          | `retro.md`, `retro-pr-{repo,factory}.md`     |

`MAX_ROUNDS = 3` review rounds per run: round `N` is the run's
`N - round_base`th (see **job.json**). `MAX_TASK_RUNS = 2` builder runs per
task (the second on `builder-escalation`). To change the factory, edit this
file, the role files in `factory/agents/`, and `factory/models.json`
(`factory/bin/models <preset>` switches it between presets).

Every agent reads `AGENTS.md` (or `CLAUDE.md`) for the repo's setup, dev server,
validation commands and conventions. Nothing repo-specific lives in these files.

## Spec and Beads

The spec and Beads do different jobs. Keep them apart.

- `spec.md` says **what** must be true when the job is done. It is the source of
  truth; acceptance criteria live there and nowhere else.
- Beads tracks **the work**: one `feature` bead per job (linked to the spec with
  `--spec-id`), one `task` child per unit of build work, and the queue of
  features waiting for `/factory next` or the autopilot.
- Agents never use `bd`, because the Codex sandbox can't open the Beads lock
  and any role may run there. They read `<job folder>/beads.md`, the snapshot
  you take before every role (see **Running a role**); the importer reads
  `<import folder>/beads.jsonl` instead.
  You make every write, from the main checkout, so parallel sessions never
  fight over it.

Beads conventions:

| Label        | On                | Meaning                                         |
| ------------ | ----------------- | ----------------------------------------------- |
| `factory`    | every factory bead| belongs to the factory                          |
| `queued`     | job bead          | waiting in the queue                            |
| `needs-human`| feature           | parked for a person                             |
| `resubmitted`| feature           | decided by its owner, waiting for the drain     |
| `final`      | task              | the "verify all acceptance criteria" task       |
| `fix`        | task              | review, rework or autopilot follow-up           |

The job bead is usually a `feature`, but an adopted `bug` or `task` works the
same way. It is `in_progress` while a job runs and `closed` when it merges.

Every task you file must survive a resume (see [resume.md](resume.md)): before
each `bd create` of a task, look for an open child of the job bead with the
same title
(`bd children <bead> --json | jq -r --arg t "<title>" '.[] | select(.title == $t and .status != "closed") | .id'`)
and reuse it instead of filing a second one.

### Brownfield rules

The factory shares Beads with people and other tools. In a repo with work
already in flight:

- Never edit the title, description, design or acceptance of a bead the
  factory didn't create. Add context with `bd comment`.
- Never claim, close, reopen or relabel a bead that is `in_progress` or
  assigned to someone else. Queue claims go through `bd ready`, which skips
  them anyway. The one exception is a bead the autopilot drain claimed for
  your run (see [adopt.md](adopt.md)).
- A job the autopilot drain ran keeps its bead (and the tasks it claimed)
  assigned to `factory-autopilot`, and `bd close` and `bd update --claim`
  refuse any other actor. In any session that writes Beads for such a job
  (`/factory resume`, `review`, `approve`, `rework`, a drop), check the
  bead's assignee (`bd show <bead> --json | jq -r '.[0].assignee'`); when it
  is `factory-autopilot`, run every `bd` write for that job as
  `BEADS_ACTOR=factory-autopilot bd ...`.
- Only add or remove the factory's own labels (`factory`, `queued`,
  `needs-human`, `resubmitted`, `final`, `fix`). Leave every other label alone.
- Depend on in-flight work instead of duplicating it. A queued job whose
  dependency is still open isn't ready, so the factory waits for it.
- Never delete a bead.

## Running a role

Look the role up in `factory/models.json`. Before any role that has a job
folder, whatever its provider, run `factory/bin/beads-snapshot <job folder>`
(once for a step that runs several roles at once):
roles read `<job folder>/beads.md` for task state, and a model swap in
`models.json` must not leave one reading a stale or missing snapshot (skip it
for the importer, which has no job).

- **anthropic**: before spawning, run
  `factory/bin/prompt-record <job folder> <key> "<the prompt>"` with the exact
  prompt line you will send (skip it for the importer, which has no job). Then
  spawn the `factory-agent` subagent with `model` set to the entry's `model`
  and the prompt `Role: factory/agents/<agent>.md. <paths> <task>`. After each
  `factory-agent` returns, run
  `factory/bin/usage-record claude <job folder> <key>` (skip it for the
  importer, which has no job). It records the subagent's tokens in
  `<job folder>/usage.jsonl` and prints nothing.
- **openai**: run, with Bash and `run_in_background: true`,
  `factory/bin/run-codex <key> <job folder> <worktree> "<paths> <task>"`.
  You are notified when it exits. For an entry with `"browser": true` it
  starts the role's agent-browser session itself, outside the sandbox. A non-zero exit is an environment failure:
  stop and tell the user, quoting the script's output.
- **codex-plugin** (only `reviewer-adversarial`): run, with Bash and
  `run_in_background: true`,
  `factory/bin/run-adversarial <job folder> <worktree> <N>`. It runs the Codex
  plugin's `adversarial-review` against `<base>`, read-only, with the spec as
  its focus, and writes `round-<N>/review-adversarial.md` itself. Exit codes
  mean the same as for `run-codex`. With provider `anthropic` or `openai`,
  `reviewer-adversarial` runs from its role file like any other role.

`<agent>` is the entry's `agent` field, or the key itself. When a step spawns
several roles at once, issue every Agent and Bash call in **one message** so
they run in parallel. After any role finishes, check that the file it should
have written exists and starts with a valid first line; if not, stop and tell
the user.

When a job reaches `merged`, `needs-human` or `dropped`, run
`factory/bin/usage-record session <job folder>`. It records your own
session's tokens for the job (once per session) and prints nothing.

### Jev

Jev answers three quick choices through `factory/bin/jev-decide`: which
builder a task gets (**Build** step 2), which reviewers a round can skip
(**Review round N** step 2) and which review Notes are worth a fix
(**Triage**). `jev` in `factory/settings.json` configures it. `send` is
`metadata` by default, and `off` turns it off. Its one output line is all you read.
You never call `factory/bin/jev` yourself, never send Jev anything, and never
override a `jev-decide` result with your own judgement. It always exits 0 and
falls back to today's behaviour when anything fails.

## Keep your context small

A job is dozens of steps, and everything you read stays in your context until
the job ends. The agents read the full files; you only route.

- Read an agent's file with `head -n 1`, plus `grep -m 1 '^Confidence:'` or a
  `sed` range for the one section you must quote. Never Read a whole spec,
  plan, report or review.
- Check `plan.json` with `jq`, not by reading it.
- Change `job.json` only with
  `factory/bin/job-set <job folder>/job.json '<jq filter>' [--arg k v ...]`,
  which prints nothing. Never write the whole file yourself.
- Pull the field you need from Beads JSON with `jq -r`, for example
  `bd ready ... --json -n 1 | jq -r '.[0].id // empty'`. Create with `--silent`.
- Pass `-q` to `git commit`, `git merge` and `git worktree add`.
- Send long output to a log: run the repo's setup, and anything else that
  prints more than a few lines, as `<cmd> >"<job folder>/.runs/<step>.log" 2>&1`,
  and print `tail -n 20` of the log only when it fails.

## Parallel jobs

Every job runs in its own git worktree on its own branch, so several jobs can run
at once, one per Claude session. Your session orchestrates only the job it
started or was handed.

- Your session stays in the main checkout. Agents work in the job's worktree.
  The main checkout is the user's, and it may be dirty or on another branch.
  Only **Merge** touches it.
- Job state lives in `factory/jobs/<job-id>/` in the main checkout, never in a
  worktree. Each job has its own `job.json`, so sessions never write the same
  file. Queue claims go through `bd update <bead> --claim`, which is atomic:
  of two sessions with different actors claiming one bead, exactly one wins
  (for the same actor `--claim` succeeds again, so the drain uses a
  compare-and-set instead).
- `factory/bin/autopilot --jobs N` runs up to N headless jobs at once (the
  `jobs` setting in `factory/settings.json`, default 1). It claims each bead
  before its session starts, as the Beads actor `factory-autopilot` (a
  compare-and-set: `bd update <bead> --status in_progress --assignee
  factory-autopilot --if-assignee '' --if-status open`), and runs
  the session with `BEADS_ACTOR=factory-autopilot`, so the session's own
  `--claim` and its `bd close` work as the same actor.
- Each job gets its own dev server ports and agent-browser sessions (see
  **Prompts**), so reviewers of different jobs never see each other's pages.

## Files

`<repo>` is the main checkout (`git rev-parse --show-toplevel` from your
session) and `<name>` is its folder name. `factory/jobs/` is gitignored runtime
state that never lands in a commit.

```
<repo>/factory/models.json                     role → provider, model, effort
<repo>/factory/autopilot-policy.md             what the autopilot may decide alone
<repo>/factory/jev/<decision>.json             Jev's questions
<repo>/factory/role-preamble.md                what every role shares, read before its role file
<repo>/factory/agents/<role>.md                one instruction file per role
<repo>/factory/jobs/<job-id>/job.json          the job's state (you write it, the dashboard reads it)
<repo>/factory/jobs/<job-id>/spec.md
<repo>/factory/jobs/<job-id>/plan.json
<repo>/factory/jobs/<job-id>/build/<task-id>.md
<repo>/factory/jobs/<job-id>/build.md
<repo>/factory/jobs/<job-id>/rework-<k>.md     from /factory rework in older jobs
<repo>/factory/jobs/<job-id>/human-brief-<k>.md the briefer's brief for the owner, from /factory review
<repo>/factory/jobs/<job-id>/human-<k>.md      the owner's decision, binding on every later role
<repo>/factory/jobs/<job-id>/round-<N>/review-{security,code,ux,ui,adversarial}.md
<repo>/factory/jobs/<job-id>/round-<N>/triage.{md,json}  Jev's sort of the Notes of an all-PASS round
<repo>/factory/jobs/<job-id>/jev.jsonl         every Jev call
<repo>/factory/jobs/<job-id>/decision.md
<repo>/factory/jobs/<job-id>/autopilot-<k>.md
<repo>/factory/jobs/<job-id>/.runs/            Codex and Claude prompts, Codex logs
<repo>/.git/refs/factory/jobs/<job-id>         local bookmark for a merged job branch
<repo>/factory/jobs/<job-id>/.resume-claim/    a drain worker holds this resubmitted job
<repo>/factory/jobs/<job-id>/retro.md         the retro: cost, causes, fixes
<repo>/factory/jobs/<job-id>/retro-pr-{repo,factory}.md  the retro PR bodies
<repo>/factory/jobs/<job-id>/retro-comment-<n>.md  a comment for factory PR <n> (.posted.md once posted)
<repo>/factory/jobs/<job-id>/retro-rejected.md  bodies of this job's closed, unmerged retro PRs
<repo>/factory/jobs/<job-id>/retro-factory-prs.json  ai-factory's factory-retro PRs
<repo>/factory/jobs/<job-id>/retro-stale.txt  installed factory files that differ from factory_source
<repo>/factory/jobs/<job-id>/retro-factory.patch  factory fixes, when factory_source is unset
<repo>/factory/jobs/<job-id>/.retro-factory/  scratch copy of the installed factory, for that patch
<repo>/../<name>-factory/<job-id>/             the job's worktree, on factory/<job-id>
<repo>/../<name>-factory/retro-<job-id>/       the retro's worktree, on factory/retro-<job-id>[-<k>]
<src>/../<srcname>-factory/retro-<name>-<job-id>/  with factory_source <src>: its retro worktree
```

### job.json

```json
{ "id": "003-rate-limiting", "feature": "Rate limit the signup form",
  "bead": "app-k2f", "autopilot": false,
  "branch": "factory/003-rate-limiting",
  "worktree": "/Users/you/code/my-app-factory/003-rate-limiting",
  "stage": "review", "round": 2, "reworks": 0, "respecs": 0, "situation": null,
  "tasks": [
    { "id": "app-k2f.1", "title": "Add limiter middleware", "status": "closed", "model": "gpt-6-luna", "role": "builder-light", "runs": 1 },
    { "id": "app-k2f.2", "title": "Verify all acceptance criteria", "status": "closed", "model": "gpt-6-luna", "role": "builder-escalation", "runs": 2, "final": true }
  ],
  "reviews": { "security": "CHANGES", "code": "PASS", "ux": "PASS", "ui": "pending", "adversarial": "PASS" },
  "updated": "2026-10-19T04:12:09Z" }
```

- `stage` is one of `spec`, `plan`, `build`, `review`, `approve`, `autopilot`,
  `merged`, `needs-human`, `resubmitted`, `dropped`. Worktree setup counts as
  `spec`. `merged` and `dropped` are end states; `resubmitted` waits for the
  drain (see [resume.md](resume.md)).
- `round` is the current review round (0 until the first round starts).
- `round_base` is the last round before the current run (read it as
  `.round_base // 0`). A rework, respec or owner decision starts a new run:
  the `job-set` that starts it sets `round_base` to the current `round`, so
  the run gets `MAX_ROUNDS` rounds of its own.
- `tasks` mirrors the job bead's children: `open`, `in_progress`, `closed` or
  `blocked`, the model that last built each, `role`, the `models.json` key that
  last built it, and `runs`, how many builder runs it has started. Append fix
  tasks as you file them, with `fix: true`.
- `reviews` holds the current round only. Each value is `pending`, `PASS`,
  `CHANGES` or `SKIPPED`. Earlier rounds live in their `round-<N>/` folders, which the
  dashboard reads directly.
- `reworks` and `respecs` count autopilot REWORK and RESPEC decisions. Owner
  decisions don't count toward them.
- `situation` is set when a job goes to **Needs human** (`plan-blocked`,
  `build-blocked`, `rounds-exhausted`, `escalated`, `merge-blocked`) and stays
  set through `autopilot` and `needs-human`. Clear it to `null` when the job
  moves on.
- `decision_file` names the autopilot file of the decision in progress while
  `stage` is `autopilot`.
- `human_decision` names the owner's latest decision file, `human-<k>.md`,
  set when the job is resubmitted. It stays set after **/factory resume** acts
  on it, as the record of what the owner decided.
- `reviewed_base` is the base commit the current review round diffs against,
  set at the start of every **Review round N**. **Merge** lands nothing on a
  base past it.
- `pr` is the job's pull request url, written by `factory/bin/land` as soon as
  the PR exists (`land: "pr"` only).
- `retro_worktree`, `retro_factory_worktree`, `retro_factory_kind` (`source`
  or `installed`), `retro_pr` and `retro_factory_pr` are written by
  `retro-prep` and `retro-publish`, never by you. The worktrees go back to
  `null` once the retro is published.
- `updated` is stamped by `job-set` on every change.
- Change it only with `factory/bin/job-set` (see **Keep your context small**).
  Together with Beads and the job folder, it is everything **/factory resume**
  needs, so update it before you start each step, not after. `worktree` is
  always an absolute path.

### Prompts

Every agent prompt starts with the job's paths:
`Job folder: <repo>/factory/jobs/<job-id>/. Worktree: <worktree>. Branch: factory/<job-id>. Bead: <bead>. Base: <base>.`
`<base>` is the ref every diff and merge check uses (`factory/bin/settings
base`: `origin/main` with `land: "pr"`, `main` with `land: "local"`). Below,
`<paths>` stands for that sentence.

Agents that open pages also get a port. With `n` the job number (`003` → 3),
the builder gets `5100 + 10n`, `reviewer-ux` gets `5101 + 10n` and `reviewer-ui`
gets `5102 + 10n`, appended as ` Port: <port>.`

## /factory <feature>

1. **Create the job.** `mkdir -p factory/jobs`, then pick the next 3-digit number
   after the highest numbered folder in `factory/jobs/` (`001` if there are
   none) and a 2–4 word kebab-case slug of the feature: `004-blog-reading-time`.
   Claim it with `mkdir factory/jobs/<job-id>` (no `-p`). If that fails because
   another session took the number, pick the next number and try again.
   The worktree path is `$(cd .. && pwd)/$(basename "$PWD")-factory/<job-id>`,
   run from `<repo>`.
2. **Bead.** If the job came from the queue or `/factory adopt`, reuse that
   bead. Otherwise create it. Then claim and link it:
   ```bash
   bd create "<feature>" --type=feature -l factory --silent        # new jobs only
   bd update <bead> --claim --add-label factory --remove-label queued
   bd update <bead> --spec-id factory/jobs/<job-id>/spec.md --external-ref factory/<job-id>
   ```
   If the bead already has a `spec_id` or `external_ref` (check
   `bd show <bead> --json`), don't overwrite it. Instead run
   `bd comment <bead> "factory/<job-id>: spec at factory/jobs/<job-id>/spec.md"`.
   Create `job.json` with `job-set`: the id, feature, bead, branch, worktree,
   `stage: "spec"`, `round: 0`, `reworks: 0`, `respecs: 0`, `situation: null`,
   empty `tasks`, all reviews `pending`, and `autopilot` true only when the
   command was `/factory autopilot`.
3. **Worktree.** Create the branch and its worktree from `<base>` (with `land: "pr"`,
   run `git fetch -q origin main` first; with `land: "local"` don't fetch):
   ```bash
   git worktree add -q -b factory/<job-id> <worktree> <base>
   ```
   Then, in the worktree, run the setup AGENTS.md gives for a fresh checkout
   (installing dependencies, for example), logging to `.runs/setup.log`. If
   any of it fails, stop and tell the user, quoting the log's tail.
4. **Spec.** Run `spec-writer` with the task `Feature: <feature, verbatim>`.
5. **Plan.** Go to **Plan**.

### Plan

1. Set `stage: "plan"`. Run `planner` with the task `Plan the spec.`
2. Check `plan.json` with `jq`. If it isn't valid JSON, stop and tell the user.
   If `status` is `BLOCKED`, go to **Needs human** with situation `plan-blocked`.
3. Check the plan with `jq` (and `grep` for the criterion numbers in
   `spec.md`): exactly one task has `"final": true`, every `depends_on` key
   exists, every `bead` field names an open child of the job bead, and the union
   of `covers` includes every acceptance criterion number in `spec.md`. If not, run `planner` once more with the task
   `Plan the spec. Your last plan.json failed this check: <what failed>.`, then
   treat a second failure as `plan-blocked`.
4. File the tasks, in plan order, then their dependencies. A task with a
   `bead` field already exists: don't create it, just
   `bd update <id> --add-label factory`. Create the rest:
   ```bash
   bd create "<title>" --type=task --parent <bead> -l factory[,final] \
     --no-inherit-labels -d "<description>

   Covers acceptance criteria: <covers>. Plan key: <key>." --silent
   bd dep add <task-id> <dependency-task-id>
   ```
   Add each task to `job.json` `tasks` (status `open`, `runs: 0`) as it is
   created.
5. Go to **Build**.

### Build

Repeat until no task under the bead is open:

1. Take the next ready task:
   `bd ready --parent <bead> -t task --sort oldest --json -n 1 | jq -r '.[0].id // empty'`.
   If none is ready but open tasks remain, they are blocked on something
   outside the plan: stop and tell the user, quoting
   `bd ready --parent <bead> --explain`.
2. Pick the role. Use `builder-escalation` when the task's `runs` is already
   1 or more, and for fix tasks when the round `N` being built for has
   `N - round_base = MAX_ROUNDS`; don't route those. Otherwise run
   `factory/bin/jev-decide route <job folder> <task-id>` and use the first word
   of its line as the role key. `bd update <task> --claim`, then in one
   `job-set` set `stage: "build"` and mark the task `in_progress` with that
   key as `role`, `model` from that key's `models.json` entry, and `runs` plus
   one. Include the line's parenthesis in the **Reporting** line. If `build/<task-id>.md` exists from an earlier run, move it to
   `build/<task-id>.run-<earlier runs>.md`, so a report at the plain path is
   always this run's.
3. Run that role with the task `Build task <task-id>. Port: <port>.`
4. Read the first line of `build/<task-id>.md`:
   - `STATUS: DONE` (or `STATUS: READY` for the final task): commit the change.
     Agents never commit (the Codex sandbox keeps `.git` read-only), so you
     do, from the report's `## Commit` section:
     ```bash
     git -C <worktree> add -- <files>
     git -C <worktree> commit -q -m "<message> (<task-id>)"
     ```
     Skip the commit when it lists no files. Then
     `git -C <worktree> status --porcelain` must print nothing. If it doesn't,
     the builder left stray changes: treat the run as BLOCKED with that output
     as the reason. Otherwise
     `bd close <task> --reason "Built by <model> in <short hash>: factory/jobs/<job-id>/build/<task-id>.md"`
     and mark it `closed`.
   - `STATUS: BLOCKED`: if the task's `runs` is below `MAX_TASK_RUNS`, go back
     to step 2 for it (it runs on `builder-escalation`). Otherwise mark it `blocked`,
     `bd comment <task> "BLOCKED: see build/<task-id>.md"`, and go to
     **Needs human** with situation `build-blocked`.

When every task is closed, read the first line of `build.md`: `STATUS: READY`
starts the next review round; anything else is `build-blocked`.

### Review round N

1. Set `stage: "review"`, `round: N` and all five reviews to `pending`. Create
   `factory/jobs/<job-id>/round-<N>/`. With `land: "pr"`, `git fetch -q origin
   main` so reviewers diff against the current `origin/main`. Then set
   `reviewed_base` to `git rev-parse <base>` (`<base>` is
   `factory/bin/settings base`).
2. Run `factory/bin/jev-decide reviewers <job folder> <N>`. It writes
   `review-<lens>.md` (`VERDICT: SKIPPED`) for each lens a change gives
   nothing to review. Write `SKIPPED` to `job.json` for each of those. Then run
   the other reviewers **in one message**, so they run in parallel. Each
   gets the task `Review round N.`, plus a port for `reviewer-ux` and
   `reviewer-ui`; on `codex-plugin`, `reviewer-adversarial` gets `N` as
   `run-adversarial`'s third argument instead.
3. **WAIT FOR ALL.** Each time a reviewer finishes, read the first line of its
   file (`VERDICT: PASS`, `VERDICT: CHANGES` or `VERDICT: SKIPPED`) and write that verdict to
   `job.json` straight away, so the dashboard chips fill in as they land. The
   round is done only when all five `review-*.md` files exist in `round-<N>/`.
   Never start a fix mid-round.
4. Check `git -C <worktree> status --porcelain --untracked-files=no` prints
   nothing. Reviewers must not change tracked files; if one did, stop and tell
   the user. Untracked caches from their checks are fine; delete them with
   `git -C <worktree> clean -fdq` (it keeps gitignored files).
5. Decide:
   - **All PASS** (`SKIPPED` counts as `PASS` here) with at least one Note line
     across the reviews, and `N - round_base < MAX_ROUNDS`: go to **Triage**.
   - **Otherwise, all PASS**: go to **Approve**.
   - **Any CHANGES, `N - round_base < MAX_ROUNDS`**: for each CHANGES review, file a fix
     task, then one new final task that depends on all of them:
     ```bash
     bd create "Fix round N <lens> review" --type=task --parent <bead> \
       -l factory,fix --no-inherit-labels \
       -d "Address every finding in factory/jobs/<job-id>/round-<N>/review-<lens>.md." --silent
     bd create "Verify all acceptance criteria (round N+1)" --type=task --parent <bead> \
       -l factory,final --no-inherit-labels \
       -d "Re-run validation and re-check every acceptance criterion in spec.md. Rewrite build.md." --silent
     bd dep add <final-task> <fix-task>      # once per fix task
     ```
     Go to **Build**.
   - **Any CHANGES, `N - round_base = MAX_ROUNDS`**: write `decision.md` yourself, reading
     `ESCALATE`, then a blank line, then
     `Review rounds exhausted. Outstanding CHANGES in round-<N>/ from: <reviewers>.`
     Go to **Needs human** with situation `rounds-exhausted`.

### Triage

Run `factory/bin/jev-decide triage <job folder> <N>`. It writes
`round-<N>/triage.json` and `triage.md`, and prints a summary line. If it
prints `off`, or `round-<N>/triage.json` doesn't exist, go to **Approve**.

1. For each `.follow_up[]` in `round-<N>/triage.json`, file a bead unless an
   open bead already has its title
   (`bd list --title "<title>" --json | jq -r --arg t "<title>" '.[] | select(.title == $t) | .id'`;
   reuse that id instead):
   ```bash
   bd create "<title>" --type=feature -p 2 -l factory,queued \
     --deps discovered-from:<bead> \
     -d "<text>\n\nFrom round <N> review Notes of factory/<job-id>." --silent
   ```
2. With `.fix_now` non-empty, file `Fix round N notes`
   (`-l factory,fix`, `-d "Address every Note under ## Fix now in factory/jobs/<job-id>/round-<N>/triage.md."`)
   and the usual `Verify all acceptance criteria (round N+1)` final task
   depending on it, exactly as a CHANGES round does. Before each `bd create`
   here, look for an open child of the job bead with the same title (the check
   **Spec and Beads** requires), and reuse it. Then go to **Build**. This
   counts as a round, and skips the approver and autopilot.
3. Otherwise go to **Approve**.

### Approve

Set `stage: "approve"`. Run `approver` with the task `Final round: N.`
If `human_decision`'s first line is `APPROVE` and no `build/*.md` is newer
than that file, this round is the re-review after an owner APPROVE met a
moved base: append
` Owner decision: <human_decision> settles the earlier escalation; judge only what the base merge changed.`
When it finishes, read the first line of `decision.md`:

- `APPROVE`: go to **Merge**.
- `ESCALATE`: go to **Needs human** with situation `escalated`.

### Merge

Every job lands through `factory/bin/land <job folder>`, never a push to
`main`. With `land: "pr"` (the default) it pushes the job branch, opens its PR
(or reuses the open one), waits for `main`'s required checks (all checks when
none are required) and squash-merges; the main checkout is never touched.
With `land: "local"` it merges `factory/<job-id>` into `main` in the main
checkout, one landing at a time, and never fetches or pushes. Either way,
nothing lands on a base past `reviewed_base`. Run it with Bash and
`run_in_background: true`. With `land: "pr"` it writes the PR url to
`job.json`'s `pr` as soon as the PR exists (and prints it as its first line).
When it exits:

- **0**: the job merged. Clean up and close:
  ```bash
  git worktree remove <worktree>
  git update-ref refs/factory/jobs/<job-id> factory/<job-id>
  git branch -D factory/<job-id>
  bd close <bead> --reason "Merged <pr>"    # local: "Merged factory/<job-id> into main"
  ```
  This is a local bookmark, never pushed, so the dashboard can show task diffs after merge.
  If removing the worktree fails, the job is still merged: tell the user what
  `git worktree remove` printed. Remove the `needs-human` label if the bead
  has it, and set `stage: "merged"` and `situation: null`. Then run
  **Retro**, then `factory/bin/usage-record session <job folder>`.
- **6** (the base moved since `reviewed_base`): `land` merged the new base
  into the job branch with a merge commit (and pushed it with `land: "pr"`;
  the PR stays open and is reused). The final review never saw that code, so
  it counts as another round: if `N - round_base < MAX_ROUNDS`, go to
  **Review round N+1**, which sets `reviewed_base` to the new base, and then
  **Approve** again. If `N - round_base = MAX_ROUNDS`, rewrite `decision.md` yourself,
  keeping the approver's text: `ESCALATE`, then a blank line, then
  `Base moved after the final review round; factory/<job-id> now merges <base> and needs another review.`,
  then a blank line, `## Approver's decision before the base moved`, and the
  old `decision.md` below it. Go to **Needs human** with situation
  `rounds-exhausted`.
- **3** (required checks failed), **4** (conflicts with `<base>`) or
  **5** (GitHub refused the merge): go to **Needs human** with situation
  `merge-blocked`, quoting the script's stderr and `tail -n 20` of
  `.runs/checks.log`. The PR stays open; a later rework pushes to the same
  branch and **Merge** reuses it.
- **7** (`land: "local"` only: the main checkout is not on `main`, has changes
  outside `factory/`, or another landing held `factory/.land-lock` for 10
  minutes): go to **Needs human** with situation `merge-blocked`, saying the
  job is approved but the main checkout is busy.
- Anything else is an environment failure: stop and tell the user.

### Retro

Works out why an expensive job needed extra attempts, and proposes fixes as
PRs for the user. A retro never changes `stage` or `situation`.

1. Unless the job came from `/factory retro`, run
   `factory/bin/retro-due <job folder>`. On exit 1, stop silently.
2. Run `factory/bin/retro-prep <job folder>` in the foreground. It prints
   three lines: `repo <path>`, `factory <path> <kind>`, then `base <ref>`.
3. Run `retro` with the task
   `Retro. Retro worktree: <repo path>. Factory worktree: <factory path> (<kind>).`
   and `<ref>` from the `base` line as `<paths>`' Base (the job's own
   worktree may already be gone; the role knows). For an `anthropic` retro,
   then run `factory/bin/usage-record claude <job folder> retro`. For an
   `openai` one, call `run-codex retro <job folder> <repo path> "<prompt>"
   <factory path>`, so the factory worktree is writable too.
4. Check that `retro.md`'s first line is `RETRO: <n> fixes` or
   `RETRO: nothing to change`.
5. Run `factory/bin/retro-publish <job folder>` and print its line.
6. On any non-zero exit or a bad first line, tell the user in one line,
   quoting stderr, and stop the retro; `/factory retro <job-id>` finishes it
   later. The job stays where it is, and a drain (`/factory autopilot` in
   this session, or headless) carries on to its next job.

### Needs human

Every stop that needs a decision comes here with a situation: `plan-blocked`,
`build-blocked`, `rounds-exhausted`, `escalated` or `merge-blocked`. Set
`situation` in `job.json` first.

- **On autopilot** (`job.json` `autopilot: true`): go to **Autopilot decision**.
- **Otherwise**: set `stage: "needs-human"`, run
  `bd update <bead> --add-label needs-human` and
  `factory/bin/usage-record session <job folder>`, and tell the user which job is
  waiting, give the worktree path, and quote `decision.md`, the BLOCKED reason
  from the build report, or `plan.json`'s `blocked`. The branch and its
  worktree stay for the human to inspect; `/factory review <job-id>` works
  through the decision with them.

### Autopilot decision

1. Pick `k`, the next unused number for `autopilot-<k>.md`. Set
   `stage: "autopilot"` and `decision_file: "autopilot-<k>.md"`.
2. Run `autopilot` with the task
   `Situation: <situation>. Decision file: autopilot-<k>.md.`
3. Read the first line and the `Confidence:` line, then
   `bd comment <bead> "autopilot-<k>: <decision>, <confidence> confidence"`.
4. Enforce the limits, turning a decision that breaks one into **PARK**:
   - **MERGE** needs situation `escalated` or `merge-blocked`, confidence
     `high` or `medium`, every final-round review `PASS` or `SKIPPED`, and
     `git merge-tree --write-tree <base> factory/<job-id>` clean (after
     `git fetch -q origin main` with `land: "pr"`).
   - **REWORK** needs `reworks < 2`. **RESPEC** needs `respecs < 1`. Owner
     REWORK and RESPEC decisions don't count.
   - Owner decisions bind the autopilot too: it reads every `human-*.md`,
     stays within the owner's scope and "do not change" lines, and PARKs
     itself when it can't. You enforce only the limits above.
5. Act on it. For REWORK and RESPEC, increment `reworks` or `respecs` and
   set `round_base` to `round` in the same `job-set` that moves the job out
   of `autopilot`, so an interrupted decision is never counted twice. MERGE
   leaves `round_base` alone: a re-review after a moved base (**Merge** exit
   6) counts against the same `MAX_ROUNDS`, so an ESCALATE → MERGE loop
   can't run forever:
   - **MERGE**: go to **Merge**. If that comes back `merge-blocked` again,
     PARK instead of asking the autopilot twice.
   - **REWORK**: file one fix task
     (`"Autopilot rework k"`, `-d "Address every instruction in factory/jobs/<job-id>/autopilot-<k>.md."`)
     and a new final task depending on it, exactly as a review round does.
     In that same `job-set`, clear `situation`; then go to **Build**.
   - **RESPEC**: run `spec-writer` with the task
     `Amend: read autopilot-<k>.md and revise spec.md.` Close every open task
     under the bead with `--reason "Superseded by respec autopilot-<k>"`, then
     clear `situation` in that same `job-set` and go to **Plan**.
   - **PARK**: set `stage: "needs-human"`, add the `needs-human` label, run
     `factory/bin/usage-record session <job folder>`, and tell
     the user what the autopilot says a human must decide, quoting its
     `## Instructions`.

## /factory add <feature> [P0-P4]

Queue a feature without running it:
`bd create "<feature>" --type=feature -l factory,queued -p <priority, default 2> --silent`.
Say the bead id.

## /factory next

Pick the next queued job with `factory/bin/next-bead`: beads carrying a
priority label from `factory/settings.json` come first, then the rest, each by
priority and then age. If it prints nothing, say the queue is empty and stop.
Claim it with `bd update <bead> --claim`; if another session claimed it first,
pick again. Otherwise run `/factory <its title>`, reusing that bead in step 2.
The bead's description goes to the spec-writer through Beads, not the prompt.

## /factory autopilot [<feature> | <job-id> | <count>]

Run with no human in the loop. Every **Needs human** goes to the autopilot
agent instead, under `factory/autopilot-policy.md` and the limits above.

- `/factory autopilot <feature>`: run one new job on autopilot.
- `/factory autopilot import <prd>` and `/factory autopilot adopt <bead>`: see
  [import.md](import.md) and [adopt.md](adopt.md); import applies without
  asking, then drains the queue.
- `/factory autopilot <job-id>`: hand a `needs-human` job to the autopilot.
  Set `autopilot: true`, remove its `needs-human` label, and go to
  **Autopilot decision** with the `situation` from its `job.json`.
- `/factory autopilot` or `/factory autopilot <count>`: drain the queue. Loop:
  take the oldest `resubmitted` job you can claim (see [resume.md](resume.md))
  and resume it, or else claim as in `/factory next`; run the job on autopilot
  to `merged`, `needs-human` or `dropped`, then take the next. Stop when the
  queue is empty or after `<count>` jobs. A parked job doesn't stop the loop.

When an autopilot run ends, print one line per job: id, bead, outcome, and the
autopilot decisions it took.

A drain in one session keeps every job in your context. For long drains the
user runs `factory/bin/autopilot` from a shell instead: it starts one headless
session per job with `/factory autopilot adopt <bead>`, and `/factory resume`
when a session ends early. It resumes `resubmitted` jobs before it starts new
beads, claiming each with `mkdir <job folder>/.resume-claim`. With
`--watch` it keeps polling when nothing is left instead of exiting, a
failed job (no job made, or resumes run out) is logged instead of ending
its worker, and `<count>` still bounds the jobs. With `--jobs N` (default: the `jobs`
setting, else 1) it runs up to N jobs at once and `<count>` counts jobs
across all of them; it claims each bead first, as `factory-autopilot`, and
says so in the prompt. In a headless
session nobody can answer: never ask a question, and run only the job you
were given.

## /factory status

Print the land mode first, as `land: <mode>` (`factory/bin/settings land`:
`pr` or `local`), then the next job (`factory/bin/next-bead`), the ready queue
(`bd ready -l factory,queued --exclude-type epic`), the
queued jobs still waiting on dependencies
(`bd blocked -l factory,queued`), the
parked jobs (`bd list -l factory,needs-human`), the jobs resubmitted by their
owner and waiting for the drain (`bd list -l factory,resubmitted`), the
`needs-human` beads with no job folder (import conflicts for
`/factory review`), and the stage of each job folder's `job.json`, `dropped`
included. Then run `factory/bin/usage-summary` and print its output
as-is (one line per job not yet merged or dropped, with token totals and
runs, then the trend over recent merged jobs and the quota lines); don't read
usage files yourself.

## /factory import <prd>

Read [import.md](import.md) when the command is `/factory import <prd>` or
`/factory autopilot import <prd>`.

## /factory adopt <bead>

Read [adopt.md](adopt.md) when the command is `/factory adopt <bead>` or
`/factory autopilot adopt <bead>`, as every headless drain session is.

## /factory review [<job-id>]

Read [review.md](review.md) when the command is `/factory review`, and
before `/factory approve` or `/factory rework`, which reuse its `k`, its
resubmit step and its drain check.

## /factory retro <job-id>

Read [retro.md](retro.md) when the command is `/factory retro <job-id>`.
The **Retro** step every merged or dropped job runs is above, not there.

## /factory approve <job-id>

A shortcut for a `/factory review` that ends in APPROVE, with no brief. The
job must be in `needs-human` with situation `escalated` or `merge-blocked`,
every review in `job.json` `PASS` or `SKIPPED` and every task closed; otherwise say so and point at
`/factory review <job-id>`. With `k` as in [review.md](review.md), write
`factory/jobs/<job-id>/human-<k>.md` yourself: `APPROVE`, a blank line,
`## Owner answers`, `/factory approve <job-id>`. Then resubmit it as in
[review.md](review.md) step 4, and end with its drain check. The drain merges
it.

## /factory rework <job-id> <note>

A shortcut for a `/factory review` that ends in REWORK, with the note as the
instructions. The job must be in `needs-human`. With `k` as in
[review.md](review.md), write `factory/jobs/<job-id>/human-<k>.md` yourself:
`REWORK`, a blank line, `## Owner answers` and the note verbatim, then
`## Instructions` and the note verbatim again. Then resubmit it as in
[review.md](review.md) step 4, and end with its drain check. The drain builds
it.

## /factory resume <job-id>

Read [resume.md](resume.md) when the command is `/factory resume <job-id>`,
or a drain picks up a `resubmitted` job.

## Reporting

Keep the user posted with one short line per transition, for example
`003-rate-limiting: round 2, security CHANGES, code/ux/ui PASS → 1 fix task (app-k2f.4) → builder gpt-6-luna`.
When the job ends, say whether it merged, was dropped or needs a human, and why. On
autopilot, also name each decision the autopilot took and its confidence.
A retro adds one line: `retro-publish`'s output, or why the retro stopped.
