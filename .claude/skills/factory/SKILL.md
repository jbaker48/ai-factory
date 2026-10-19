---
name: factory
description: Run the software factory. Use when the user types /factory <feature>, /factory add, /factory next, /factory autopilot, /factory import <prd>, /factory adopt <bead>, /factory status, /factory approve <job-id>, or /factory rework <job-id> <note>. The session that runs it becomes the orchestrator of the spec → plan → build → review → approve loop, with Beads tracking the work and Claude and OpenAI models doing it.
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
| build     | `builder` / `builder-escalation` | `build/<task-id>.md`, `build.md` (you commit) |
| review    | `reviewer-security`              | `round-N/review-security.md`                 |
|           | `reviewer-code`                  | `round-N/review-code.md`                     |
|           | `reviewer-ux`                    | `round-N/review-ux.md`                       |
|           | `reviewer-ui`                    | `round-N/review-ui.md`                       |
|           | `reviewer-adversarial`           | `round-N/review-adversarial.md`              |
| approve   | `approver`                       | `decision.md`                                |
| autopilot | `autopilot`                      | `autopilot-<k>.md`                           |

`MAX_ROUNDS = 3` review rounds per run. `MAX_TASK_RUNS = 2` builder runs per
task (the second on `builder-escalation`). To change the factory, edit this
file, the role files in `factory/agents/`, and `factory/models.json`.

Every agent reads `AGENTS.md` (or `CLAUDE.md`) for the repo's setup, dev server,
validation commands and conventions. Nothing repo-specific lives in these files.

## Spec and Beads

The spec and Beads do different jobs. Keep them apart.

- `spec.md` says **what** must be true when the job is done. It is the source of
  truth; acceptance criteria live there and nowhere else.
- Beads tracks **the work**: one `feature` bead per job (linked to the spec with
  `--spec-id`), one `task` child per unit of build work, and the queue of
  features waiting for `/factory next` or the autopilot.
- Agents only read Beads (`bd --readonly`). You make every write, from the main
  checkout, so the Codex sandbox and parallel sessions never fight over it.

Beads conventions:

| Label        | On                | Meaning                                         |
| ------------ | ----------------- | ----------------------------------------------- |
| `factory`    | every factory bead| belongs to the factory                          |
| `queued`     | job bead          | waiting in the queue                            |
| `needs-human`| feature           | parked for a person                             |
| `final`      | task              | the "verify all acceptance criteria" task       |
| `fix`        | task              | review, rework or autopilot follow-up           |

The job bead is usually a `feature`, but an adopted `bug` or `task` works the
same way. It is `in_progress` while a job runs and `closed` when it merges.

### Brownfield rules

The factory shares Beads with people and other tools. In a repo with work
already in flight:

- Never edit the title, description, design or acceptance of a bead the
  factory didn't create. Add context with `bd comment`.
- Never claim, close, reopen or relabel a bead that is `in_progress` or
  assigned to someone else. Queue claims go through `bd ready`, which skips
  them anyway.
- Only add or remove the factory's own labels (`factory`, `queued`,
  `needs-human`, `final`, `fix`). Leave every other label alone.
- Depend on in-flight work instead of duplicating it. A queued job whose
  dependency is still open isn't ready, so the factory waits for it.
- Never delete a bead.

## Running a role

Look the role up in `factory/models.json`.

- **anthropic**: spawn the `factory-agent` subagent with `model` set to the
  entry's `model` and the prompt `Role: factory/agents/<agent>.md. <paths> <task>`.
- **openai**: run, with Bash and `run_in_background: true`,
  `factory/bin/run-codex <key> <job folder> <worktree> "<paths> <task>"`.
  You are notified when it exits. A non-zero exit is an environment failure:
  stop and tell the user, quoting the script's output.
- **codex-plugin** (only `reviewer-adversarial`): run, with Bash and
  `run_in_background: true`,
  `factory/bin/run-adversarial <job folder> <worktree> <N>`. It runs the Codex
  plugin's `adversarial-review` against `main`, read-only, with the spec as
  its focus, and writes `round-<N>/review-adversarial.md` itself. Exit codes
  mean the same as for `run-codex`.

`<agent>` is the entry's `agent` field, or the key itself. When a step spawns
several roles at once, issue every Agent and Bash call in **one message** so
they run in parallel. After any role finishes, check that the file it should
have written exists and starts with a valid first line; if not, stop and tell
the user.

## Parallel jobs

Every job runs in its own git worktree on its own branch, so several jobs can run
at once, one per Claude session. Your session orchestrates only the job it
started or was handed.

- Your session stays in the main checkout. Agents work in the job's worktree.
  The main checkout is the user's, and it may be dirty or on another branch.
  Only **Merge** touches it.
- Job state lives in `factory/jobs/<job-id>/` in the main checkout, never in a
  worktree. Each job has its own `job.json`, so sessions never write the same
  file. Queue claims go through `bd ready --claim`, which is atomic.
- Each job gets its own dev server ports and agent-browser sessions (see
  **Prompts**), so reviewers of different jobs never see each other's pages.

## Files

`<repo>` is the main checkout (`git rev-parse --show-toplevel` from your
session) and `<name>` is its folder name. `factory/jobs/` is gitignored runtime
state that never lands in a commit.

```
<repo>/factory/models.json                     role → provider, model, effort
<repo>/factory/autopilot-policy.md             what the autopilot may decide alone
<repo>/factory/agents/<role>.md                one instruction file per role
<repo>/factory/jobs/<job-id>/job.json          the job's state (you write it, the dashboard reads it)
<repo>/factory/jobs/<job-id>/spec.md
<repo>/factory/jobs/<job-id>/plan.json
<repo>/factory/jobs/<job-id>/build/<task-id>.md
<repo>/factory/jobs/<job-id>/build.md
<repo>/factory/jobs/<job-id>/rework-<k>.md     written by you, from /factory rework
<repo>/factory/jobs/<job-id>/round-<N>/review-{security,code,ux,ui,adversarial}.md
<repo>/factory/jobs/<job-id>/decision.md
<repo>/factory/jobs/<job-id>/autopilot-<k>.md
<repo>/factory/jobs/<job-id>/.runs/            Codex prompts and logs, from run-codex
<repo>/../<name>-factory/<job-id>/             the job's worktree, on factory/<job-id>
```

### job.json

```json
{ "id": "003-rate-limiting", "feature": "Rate limit the signup form",
  "bead": "app-k2f", "autopilot": false,
  "branch": "factory/003-rate-limiting",
  "worktree": "/Users/you/code/my-app-factory/003-rate-limiting",
  "stage": "review", "round": 2, "reworks": 0, "respecs": 0,
  "tasks": [
    { "id": "app-k2f.1", "title": "Add limiter middleware", "status": "closed", "model": "gpt-6-luna" },
    { "id": "app-k2f.2", "title": "Verify all acceptance criteria", "status": "closed", "model": "gpt-6-luna", "final": true }
  ],
  "reviews": { "security": "CHANGES", "code": "PASS", "ux": "PASS", "ui": "pending", "adversarial": "PASS" } }
```

- `stage` is one of `spec`, `plan`, `build`, `review`, `approve`, `autopilot`,
  `merged`, `needs-human`. Worktree setup counts as `spec`.
- `round` is the current review round (0 until the first round starts).
- `tasks` mirrors the job bead's children: `open`, `in_progress`, `closed` or
  `blocked`, and the model that last built each. Append fix tasks as you file
  them.
- `reviews` holds the current round only. Each value is `pending`, `PASS` or
  `CHANGES`. Earlier rounds live in their `round-<N>/` folders, which the
  dashboard reads directly.
- `reworks` and `respecs` count autopilot REWORK and RESPEC decisions.
- Rewrite the whole file on every change. `worktree` is always an absolute path.

### Prompts

Every agent prompt starts with the job's paths:
`Job folder: <repo>/factory/jobs/<job-id>/. Worktree: <worktree>. Branch: factory/<job-id>. Bead: <bead>.`
Below, `<paths>` stands for that sentence.

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
   Write `job.json` with the bead, the worktree, `stage: "spec"`, `round: 0`,
   empty `tasks`, all reviews `pending`, and `autopilot` true only when the
   command was `/factory autopilot`.
3. **Worktree.** Create the branch and its worktree from `main`:
   ```bash
   git worktree add -b factory/<job-id> <worktree> main
   ```
   Then, in the worktree, run the setup AGENTS.md gives for a fresh checkout
   (installing dependencies, for example). If any of it fails, stop and tell
   the user.
4. **Spec.** Run `spec-writer` with the task `Feature: <feature, verbatim>`.
5. **Plan.** Go to **Plan**.

### Plan

1. Set `stage: "plan"`. Run `planner` with the task `Plan the spec.`
2. Read `plan.json`. If it isn't valid JSON, stop and tell the user. If
   `status` is `BLOCKED`, go to **Needs human** with situation `plan-blocked`.
3. Check the plan: exactly one task has `"final": true`, every `depends_on` key
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
   Add each task to `job.json` `tasks` as it is created.
5. Go to **Build**.

### Build

Repeat until no task under the bead is open:

1. Take the next ready task:
   `bd ready --parent <bead> -t task --sort oldest --json -n 1`. If none is
   ready but open tasks remain, they are blocked on something outside the plan:
   stop and tell the user, quoting `bd ready --parent <bead> --explain`.
2. Set `stage: "build"`. `bd update <task> --claim`, and mark it `in_progress`
   with its model in `job.json`.
3. Run the builder with the task `Build task <task-id>. Port: <port>.` Use
   `builder`, except use `builder-escalation` for a task's second run and for
   fix tasks when the round being built for is `MAX_ROUNDS`.
4. Read the first line of `build/<task-id>.md`:
   - `STATUS: DONE` (or `STATUS: READY` for the final task): commit the change.
     Agents never commit (the Codex sandbox keeps `.git` read-only), so you
     do, from the report's `## Commit` section:
     ```bash
     git -C <worktree> add -- <files>
     git -C <worktree> commit -m "<message> (<task-id>)"
     ```
     Skip the commit when it lists no files. Then
     `git -C <worktree> status --porcelain` must print nothing. If it doesn't,
     the builder left stray changes: treat the run as BLOCKED with that output
     as the reason. Otherwise
     `bd close <task> --reason "Built by <model> in <short hash>: factory/jobs/<job-id>/build/<task-id>.md"`
     and mark it `closed`.
   - `STATUS: BLOCKED`: if this was the task's first run, run it again on
     `builder-escalation`. If it was the second, mark it `blocked`,
     `bd comment <task> "BLOCKED: see build/<task-id>.md"`, and go to
     **Needs human** with situation `build-blocked`.

When every task is closed, read the first line of `build.md`: `STATUS: READY`
starts the next review round; anything else is `build-blocked`.

### Review round N

1. Set `stage: "review"`, `round: N` and all five reviews to `pending`. Create
   `factory/jobs/<job-id>/round-<N>/`.
2. Run all five reviewers **in one message**, so they run in parallel. The
   four with role files get the task `Review round N.`, plus a port for
   `reviewer-ux` and `reviewer-ui`. `reviewer-adversarial` gets `N` as
   `run-adversarial`'s third argument.
3. **WAIT FOR ALL.** Each time a reviewer finishes, read the first line of its
   file (`VERDICT: PASS` or `VERDICT: CHANGES`) and write that verdict to
   `job.json` straight away, so the dashboard chips fill in as they land. The
   round is done only when all five `review-*.md` files exist in `round-<N>/`.
   Never start a fix mid-round.
4. Check `git -C <worktree> status --porcelain --untracked-files=no` prints
   nothing. Reviewers must not change tracked files; if one did, stop and tell
   the user. Untracked caches from their checks are fine; delete them with
   `git -C <worktree> clean -fdq` (it keeps gitignored files).
5. Decide:
   - **All PASS**: go to **Approve**.
   - **Any CHANGES, `N < MAX_ROUNDS`**: for each CHANGES review, file a fix
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
   - **Any CHANGES, `N = MAX_ROUNDS`**: write `decision.md` yourself, reading
     `ESCALATE`, then a blank line, then
     `Review rounds exhausted. Outstanding CHANGES in round-<N>/ from: <reviewers>.`
     Go to **Needs human** with situation `rounds-exhausted`.

### Approve

Set `stage: "approve"`. Run `approver` with the task `Final round: N.`
When it finishes, read the first line of `decision.md`:

- `APPROVE`: go to **Merge**.
- `ESCALATE`: go to **Needs human** with situation `escalated`.

### Merge

The merge happens in the main checkout, so it must be clean and on `main`:
`git status --porcelain -- . ':!factory/'` prints nothing and
`git branch --show-current` prints `main`. If not, go to **Needs human** with
situation `merge-blocked`, saying the job is approved but the main checkout is
busy. Otherwise:

```bash
git merge --no-ff factory/<job-id> -m "Merge factory/<job-id>"
git worktree remove <worktree>
git branch -d factory/<job-id>
bd close <bead> --reason "Merged factory/<job-id> into main"
```

Remove the `needs-human` label if the bead has it, and set `stage: "merged"`.
If the merge fails, run `git merge --abort` (when a merge is in progress) and go
to **Needs human** with situation `merge-blocked`. If removing the worktree
fails, the job is still merged: tell the user what `git worktree remove`
printed. Never push.

### Needs human

Every stop that needs a decision comes here with a situation: `plan-blocked`,
`build-blocked`, `rounds-exhausted`, `escalated` or `merge-blocked`.

- **On autopilot** (`job.json` `autopilot: true`): go to **Autopilot decision**.
- **Otherwise**: set `stage: "needs-human"`, run
  `bd update <bead> --add-label needs-human`, and tell the user which job is
  waiting, give the worktree path, and quote `decision.md`, the BLOCKED reason
  from the build report, or `plan.json`'s `blocked`. The branch and its
  worktree stay for the human to inspect.

### Autopilot decision

1. Set `stage: "autopilot"`. Pick `k`, the next unused number for
   `autopilot-<k>.md`.
2. Run `autopilot` with the task
   `Situation: <situation>. Decision file: autopilot-<k>.md.`
3. Read the first line and the `Confidence:` line, then
   `bd comment <bead> "autopilot-<k>: <decision>, <confidence> confidence"`.
4. Enforce the limits, turning a decision that breaks one into **PARK**:
   - **MERGE** needs situation `escalated` or `merge-blocked`, confidence
     `high` or `medium`, all five final-round reviews `PASS`, and
     `git merge-tree --write-tree main factory/<job-id>` clean.
   - **REWORK** needs `reworks < 2`. **RESPEC** needs `respecs < 1`.
5. Act on it:
   - **MERGE**: go to **Merge**. If that comes back `merge-blocked` again,
     PARK instead of asking the autopilot twice.
   - **REWORK**: increment `reworks`. File one fix task
     (`"Autopilot rework k"`, `-d "Address every instruction in factory/jobs/<job-id>/autopilot-<k>.md."`)
     and a new final task depending on it, exactly as a review round does. The
     next run gets a fresh `MAX_ROUNDS`, counting on from the current round.
     Go to **Build**.
   - **RESPEC**: increment `respecs`. Run `spec-writer` with the task
     `Amend: read autopilot-<k>.md and revise spec.md.` Close every open task
     under the bead with `--reason "Superseded by respec autopilot-<k>"`, then
     go to **Plan**.
   - **PARK**: set `stage: "needs-human"`, add the `needs-human` label, and tell
     the user what the autopilot says a human must decide, quoting its
     `## Instructions`.

## /factory add <feature> [P0-P4]

Queue a feature without running it:
`bd create "<feature>" --type=feature -l factory,queued -p <priority, default 2> --silent`.
Say the bead id.

## /factory next

Claim the highest-priority queued job:
`bd ready -l factory,queued --exclude-type epic --claim --json -n 1`. If it returns
nothing, say the queue is empty and stop. Otherwise run `/factory <its title>`,
reusing that bead in step 2. The bead's description goes to the spec-writer
through Beads, not the prompt.

## /factory autopilot [<feature> | <job-id> | <count>]

Run with no human in the loop. Every **Needs human** goes to the autopilot
agent instead, under `factory/autopilot-policy.md` and the limits above.

- `/factory autopilot <feature>`: run one new job on autopilot.
- `/factory autopilot import <prd>` and `/factory autopilot adopt <bead>`: see
  those commands; import applies without asking, then drains the queue.
- `/factory autopilot <job-id>`: hand a `needs-human` job to the autopilot.
  Set `autopilot: true`, remove its `needs-human` label, and go to
  **Autopilot decision** with the situation that parked it.
- `/factory autopilot` or `/factory autopilot <count>`: drain the queue. Loop:
  claim as in `/factory next`, run the job on autopilot to `merged` or
  `needs-human`, then claim the next. Stop when the queue is empty or after
  `<count>` jobs. A parked job doesn't stop the loop.

When an autopilot run ends, print one line per job: id, bead, outcome, and the
autopilot decisions it took.

## /factory status

Print the ready queue (`bd ready -l factory,queued --exclude-type epic`), the
queued jobs still waiting on dependencies
(`bd blocked -l factory,queued`), the
parked jobs (`bd list -l factory,needs-human`), and the stage of each job
folder's `job.json`.

## /factory import <prd>

Bring a PRD into a repo that already has beads, without duplicating or
trampling work in flight.

1. Create `factory/imports/<YYYY-MM-DD>-<prd-slug>/` (gitignored, like
   `factory/jobs/`).
2. Run `importer` with the task
   `Repo: <repo>. PRD: <absolute prd path>. Import folder: <absolute folder>.`
   in place of `<paths> <task>`: it has no job, worktree or bead. For an
   OpenAI role, call `run-codex` with the import folder as `<job folder>` and
   `<repo>` as `<worktree>`.
3. Read `import.json` (stop if it isn't valid JSON) and show the user a table:
   per action, the beads and titles, then the conflicts in full. Unless the
   command was `/factory autopilot import <prd>`, ask once for go-ahead and
   apply only what they accept.
4. Apply it, in this order:
   - **create**: `bd create "<title>" --type=feature -l factory,queued -p <priority> --silent`
     with `-d "<description>\n\nPRD: <prd> § <prd_section>"`. Note each
     key's new id.
   - **adopt**: skip it if the bead is now `in_progress` or assigned. Otherwise
     `bd update <bead> --add-label factory,queued`, plus
     `bd comment <bead> "PRD <prd> § <prd_section>: <context>"` when there is
     context.
   - **depends_on** for create and adopt items, with keys resolved to ids:
     `bd dep add <item> <dependency>`.
   - **conflict**: `bd comment <bead> "PRD conflict: <reason>"` and
     `bd update <bead> --add-label needs-human`. Queue nothing for it.
   - **done** and **owned**: write nothing.
5. Write `applied.md` in the import folder: what was created, adopted and
   flagged, with ids. Then print the new ready queue. The work runs through
   `/factory next` or `/factory autopilot` like any other queued job.

On autopilot, conflicts still get `needs-human`: the autopilot decides about
jobs, not about contradictions between a PRD and someone else's bead.

## /factory adopt <bead>

Run the factory on a bead that already exists.

- A `feature`, `bug` or `task` that is open and not assigned to someone else
  becomes a job now. Run `/factory <its title>`, reusing it in step 2. Its
  existing children are kept: the planner reuses those that fit.
- An `epic` isn't a job. Queue its open, unassigned, non-epic children with
  `bd update <child> --add-label factory,queued` and print them.
- Anything `in_progress` or assigned to someone else: refuse, say who has it,
  and suggest `bd dep add` so new factory work can wait for it.

`/factory autopilot adopt <bead>` does the same with `autopilot: true`.

## /factory approve <job-id>

The job must be in `needs-human`. Run **Merge** with that job id.

## /factory rework <job-id> <note>

The job must be in `needs-human`.

1. Write the note, verbatim, to `factory/jobs/<job-id>/rework-<k>.md`, where `k`
   is the next unused number.
2. Remove the `needs-human` label. File one fix task
   (`"Rework k"`, `-d "Address factory/jobs/<job-id>/rework-<k>.md."`) and a new
   final task depending on it, exactly as a review round does.
3. Go to **Build**. A rework run gets a fresh `MAX_ROUNDS`, counting on from
   the job's last round.

## Reporting

Keep the user posted with one short line per transition, for example
`003-rate-limiting: round 2, security CHANGES, code/ux/ui PASS → 1 fix task (app-k2f.4) → builder gpt-6-luna`.
When the job ends, say whether it merged or needs a human, and why. On
autopilot, also name each decision the autopilot took and its confidence.
