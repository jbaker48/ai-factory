---
name: factory
description: Run the software factory. Use when the user types /factory <feature>, /factory add, /factory next, /factory autopilot, /factory import <prd>, /factory adopt <bead>, /factory status, /factory approve <job-id>, /factory rework <job-id> <note>, or /factory resume <job-id>. The session that runs it becomes the orchestrator of the spec → plan → build → review → approve loop, with Beads tracking the work and Claude and OpenAI models doing it.
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

Every task you file must survive a resume (see **/factory resume**): before
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
  After each `factory-agent` returns, run
  `factory/bin/usage-record claude <job folder> <key>` (skip it for the
  importer, which has no job). It records the subagent's tokens in
  `<job folder>/usage.jsonl` and prints nothing.
- **openai**: first run `factory/bin/beads-snapshot <job folder>` (Codex
  can't open the Beads lock; roles read `<job folder>/beads.md` instead; skip
  it for the importer, which has no job). Then run, with Bash and
  `run_in_background: true`,
  `factory/bin/run-codex <key> <job folder> <worktree> "<paths> <task>"`.
  You are notified when it exits. A non-zero exit is an environment failure:
  stop and tell the user, quoting the script's output.
- **codex-plugin** (only `reviewer-adversarial`): run, with Bash and
  `run_in_background: true`,
  `factory/bin/run-adversarial <job folder> <worktree> <N>`. It runs the Codex
  plugin's `adversarial-review` against `<base>`, read-only, with the spec as
  its focus, and writes `round-<N>/review-adversarial.md` itself. Exit codes
  mean the same as for `run-codex`.

`<agent>` is the entry's `agent` field, or the key itself. When a step spawns
several roles at once, issue every Agent and Bash call in **one message** so
they run in parallel. After any role finishes, check that the file it should
have written exists and starts with a valid first line; if not, stop and tell
the user.

When a job reaches `merged`, `needs-human` or `dropped`, run
`factory/bin/usage-record session <job folder>`. It records your own
session's tokens for the job (once per session) and prints nothing.

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
  "stage": "review", "round": 2, "reworks": 0, "respecs": 0, "situation": null,
  "tasks": [
    { "id": "app-k2f.1", "title": "Add limiter middleware", "status": "closed", "model": "gpt-6-luna", "runs": 1 },
    { "id": "app-k2f.2", "title": "Verify all acceptance criteria", "status": "closed", "model": "gpt-6-luna", "runs": 2, "final": true }
  ],
  "reviews": { "security": "CHANGES", "code": "PASS", "ux": "PASS", "ui": "pending", "adversarial": "PASS" },
  "updated": "2026-10-19T04:12:09Z" }
```

- `stage` is one of `spec`, `plan`, `build`, `review`, `approve`, `autopilot`,
  `merged`, `needs-human`. Worktree setup counts as `spec`.
- `round` is the current review round (0 until the first round starts).
- `tasks` mirrors the job bead's children: `open`, `in_progress`, `closed` or
  `blocked`, the model that last built each, and `runs`, how many builder runs
  it has started. Append fix tasks as you file them.
- `reviews` holds the current round only. Each value is `pending`, `PASS` or
  `CHANGES`. Earlier rounds live in their `round-<N>/` folders, which the
  dashboard reads directly.
- `reworks` and `respecs` count autopilot REWORK and RESPEC decisions.
- `situation` is set when a job goes to **Needs human** (`plan-blocked`,
  `build-blocked`, `rounds-exhausted`, `escalated`, `merge-blocked`) and stays
  set through `autopilot` and `needs-human`. Clear it to `null` when the job
  moves on.
- `decision_file` names the autopilot file of the decision in progress while
  `stage` is `autopilot`.
- `reviewed_base` is the base commit the current review round diffs against,
  set at the start of every **Review round N**. **Merge** lands nothing on a
  base past it.
- `pr` is the job's pull request url, written by `factory/bin/land` as soon as
  the PR exists (`land: "pr"` only).
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
2. Pick the model: `builder`, except `builder-escalation` when the task's
   `runs` is already 1 or more, and for fix tasks when the round being built
   for is `MAX_ROUNDS`. `bd update <task> --claim`, then in one `job-set` set
   `stage: "build"` and mark the task `in_progress` with that model and `runs`
   plus one. If `build/<task-id>.md` exists from an earlier run, move it to
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
  git branch -D factory/<job-id>
  bd close <bead> --reason "Merged <pr>"    # local: "Merged factory/<job-id> into main"
  ```
  Remove the `needs-human` label if the bead has it, and set
  `stage: "merged"` and `situation: null`, then run
  `factory/bin/usage-record session <job folder>`. If removing the worktree fails,
  the job is still merged: tell the user what `git worktree remove` printed.
- **6** (the base moved since `reviewed_base`): `land` merged the new base
  into the job branch with a merge commit (and pushed it with `land: "pr"`;
  the PR stays open and is reused). The final review never saw that code, so
  it counts as another round: if `N < MAX_ROUNDS`, go to
  **Review round N+1**, which sets `reviewed_base` to the new base, and then
  **Approve** again. If `N = MAX_ROUNDS`, rewrite `decision.md` yourself,
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
  worktree stay for the human to inspect.

### Autopilot decision

1. Pick `k`, the next unused number for `autopilot-<k>.md`. Set
   `stage: "autopilot"` and `decision_file: "autopilot-<k>.md"`.
2. Run `autopilot` with the task
   `Situation: <situation>. Decision file: autopilot-<k>.md.`
3. Read the first line and the `Confidence:` line, then
   `bd comment <bead> "autopilot-<k>: <decision>, <confidence> confidence"`.
4. Enforce the limits, turning a decision that breaks one into **PARK**:
   - **MERGE** needs situation `escalated` or `merge-blocked`, confidence
     `high` or `medium`, all five final-round reviews `PASS`, and
     `git merge-tree --write-tree <base> factory/<job-id>` clean (after
     `git fetch -q origin main` with `land: "pr"`).
   - **REWORK** needs `reworks < 2`. **RESPEC** needs `respecs < 1`.
5. Act on it. Increment `reworks` or `respecs` in the same `job-set` that
   moves the job out of `autopilot`, so an interrupted decision is never
   counted twice:
   - **MERGE**: go to **Merge**. If that comes back `merge-blocked` again,
     PARK instead of asking the autopilot twice.
   - **REWORK**: file one fix task
     (`"Autopilot rework k"`, `-d "Address every instruction in factory/jobs/<job-id>/autopilot-<k>.md."`)
     and a new final task depending on it, exactly as a review round does.
     Then increment `reworks`, clear `situation`, and go to **Build**. The
     next run gets a fresh `MAX_ROUNDS`, counting on from the current round.
   - **RESPEC**: run `spec-writer` with the task
     `Amend: read autopilot-<k>.md and revise spec.md.` Close every open task
     under the bead with `--reason "Superseded by respec autopilot-<k>"`, then
     increment `respecs`, clear `situation`, and go to **Plan**.
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
  those commands; import applies without asking, then drains the queue.
- `/factory autopilot <job-id>`: hand a `needs-human` job to the autopilot.
  Set `autopilot: true`, remove its `needs-human` label, and go to
  **Autopilot decision** with the `situation` from its `job.json`.
- `/factory autopilot` or `/factory autopilot <count>`: drain the queue. Loop:
  claim as in `/factory next`, run the job on autopilot to `merged` or
  `needs-human`, then claim the next. Stop when the queue is empty or after
  `<count>` jobs. A parked job doesn't stop the loop.

When an autopilot run ends, print one line per job: id, bead, outcome, and the
autopilot decisions it took.

A drain in one session keeps every job in your context. For long drains the
user runs `factory/bin/autopilot` from a shell instead: it starts one headless
session per job with `/factory autopilot adopt <bead>`, and `/factory resume`
when a session ends early. In a headless session nobody can answer: never ask
a question, and run only the job you were given.

## /factory status

Print the next job (`factory/bin/next-bead`), the ready queue
(`bd ready -l factory,queued --exclude-type epic`), the
queued jobs still waiting on dependencies
(`bd blocked -l factory,queued`), the
parked jobs (`bd list -l factory,needs-human`), and the stage of each job
folder's `job.json`. Then run `factory/bin/usage-summary` and print its output
as-is (one line per job with token totals and runs, then the quota lines);
don't read usage files yourself.

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
   final task depending on it, exactly as a review round does. Clear
   `situation`.
3. Go to **Build**. A rework run gets a fresh `MAX_ROUNDS`, counting on from
   the job's last round.

## /factory resume <job-id>

Pick up a job whose orchestrator session ended mid-step: a closed terminal, a
crash, or a headless run stopped by its budget, a time limit or SIGTERM. Only
resume a job no other session is driving. The state is `job.json`, Beads and
the job folder; don't read more of the job than the step below needs.

1. Read the state with
   `jq -c '{stage, round, situation, decision_file, autopilot, tasks: [.tasks[] | select(.status != "closed")]}' job.json`.
   If `stage` is `merged`, say so and stop. If it is `needs-human`, say which
   situation parked it and point at `/factory approve`, `/factory rework` and
   `/factory autopilot <job-id>`, then stop.
2. Make sure nothing from the old session is still running. If
   `pgrep -fl -- "<worktree>"` lists a `codex` or `codex-companion` process,
   stop and tell the user: another session may still own the job, or the
   process is orphaned and they should kill it. Then free the job's three
   ports (`lsof -ti tcp:<port> | xargs kill`, ignoring errors) and close its
   agent-browser sessions (`agent-browser --session <job-id>-<builder|ux|ui> close`,
   ignoring errors).
3. Check whether the job already landed:
   - With `land: "pr"`, take `pr` from `job.json`; if it is unset, look for
     a merged one with
     `gh pr list --head factory/<job-id> --state merged --json url -q '.[0].url // empty'`
     and set `pr` from it. If there is a `pr`, check it with
     `gh pr view <pr> --json state -q .state`. `MERGED`: finish **Merge** from
     its exit-0 cleanup and stop. `OPEN` with `stage` `approve` or `autopilot`
     after a MERGE decision: run **Merge** again (it reuses the PR).
   - With `land: "local"`, if `factory/<job-id>` is already merged into `main`
     (`git merge-base --is-ancestor factory/<job-id> main`), finish **Merge**
     from its exit-0 cleanup and stop. If the main checkout has a merge in
     progress for it, `git merge --abort` and go to **Merge**.
4. Check the worktree exists and
   `git -C <worktree> branch --show-current` prints `factory/<job-id>`. If the
   worktree is missing and `stage` is `spec`, create it as in step 3 of
   **/factory <feature>**; otherwise stop and tell the user.
5. Go back in by `stage`:
   - **spec**: run the repo's setup again (AGENTS.md says it is safe to
     re-run). If `spec.md` is missing, go to step 4 of **/factory <feature>**;
     otherwise go to **Plan**.
   - **plan**: if `tasks` is empty, go to **Plan**. Otherwise the tasks were
     being filed: continue from **Plan** step 4 (filing skips tasks that
     already exist), then go to **Build**.
   - **build**: take the `in_progress` task, if there is one. If
     `build/<task-id>.md` exists, its run finished: continue from **Build**
     step 4. If not, the run was cut off: throw away its partial change
     (`git -C <worktree> reset -q --hard && git -C <worktree> clean -fdq`),
     set the task back to `open` with `runs` minus one, and go to **Build**.
     With no `in_progress` task, go to **Build**.
   - **review**: for each lens whose `round-<N>/review-<lens>.md` exists with a
     valid first line, write its verdict to `job.json`. Run the missing
     reviewers as in **Review round N** step 2, then continue from step 3.
   - **approve**: if `decision.md` is newer than every file in `round-<N>/`,
     use it as in **Approve**. Otherwise run **Approve** again.
   - **autopilot**: if `decision_file` exists with a valid first line, continue
     from **Autopilot decision** step 3. Otherwise run step 2 with that file.
6. Tell the user, in one line, where the job went back in, then carry on as
   usual. `autopilot` stays as `job.json` has it.

## Reporting

Keep the user posted with one short line per transition, for example
`003-rate-limiting: round 2, security CHANGES, code/ux/ui PASS → 1 fix task (app-k2f.4) → builder gpt-6-luna`.
When the job ends, say whether it merged or needs a human, and why. On
autopilot, also name each decision the autopilot took and its confidence.
