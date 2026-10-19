# Factory: retro after expensive jobs

- Date: 2026-10-20
- Status: ready for review by the user
- Inputs: garmin-ai-coach jobs `001-event-bus-tenant-boundary` and
  `002-eval-gate-blocking` (`~/Development/garmin-ai-coach/factory/jobs/`),
  `docs/findings/2026-10-19-token-efficiency-first-run.md`, and the factory as
  merged in PR #3

## Why

Tokens get wasted on jobs that keep iterating, and the factory learns nothing
from them. Job 001 took 8 review rounds and 5 reworks, all written by the
owner by hand, to land a test assertion and a runbook. Reading its job folder
afterwards turned up causes that were fixable, and each would have saved
rounds on later jobs:

1. **Spec gap.** The spec required proof of "exactly one CheckIn". A standard
   SQS queue delivers at least once, so no time window can prove that. This
   only came out in round 4 (`rework-2.md`).
2. **Findings arrive one at a time.** Each round, the adversarial reviewer
   found one new defect: uniqueness, then the delivery window, the zero-valued
   metric, the CDK logical ID, policy enumeration, literal role names.
3. **The verdict hides the real problem.** All five reviewers said `PASS` in
   every round. The real blockers sat in the adversarial review's `## Notes`
   at medium severity, below `block_on`. The approver escalated on them
   anyway, so the review verdicts carried no signal.
4. **Reviews with nothing to review.** UI and UX reviewed a docs-plus-test
   diff 8 times.
5. **Environment.** The Beads lock and git temp files failed in the sandbox,
   so the approver's gates could never be verified (`decision-round1.md`).
6. **Repo knowledge.** CDK appends a hash to logical IDs. SQS delivers at least
   once. Neither is in garmin-ai-coach's `AGENTS.md`.

Job 002 also qualifies: it had one respec, and one builder task needed 2 runs.

The user wants the factory to **draft the fixes for them to approve**, not
just write a report, because more iterations are where the tokens go.

## Goals

- Run a retro after every expensive job, without being asked.
- The retro works out why each extra round, rework, respec or rerun happened.
- It drafts concrete fixes, sent where they belong:
  - **repo knowledge** goes to the target repo's `AGENTS.md`;
  - **factory problems** go to the ai-factory source (role prompts,
    `SKILL.md`, `models.json`, `autopilot-policy.md`, scripts);
  - **follow-up work** becomes drafted Beads.
- The user approves every fix by reviewing a PR (or a branch) before it lands.
- Show whether the factory is improving: rounds, reworks and tokens per job
  over time.

## Non-goals

- The research agent. It is a separate project. Retros will record how often
  missing external knowledge caused rounds (cause 1 above), and that evidence
  decides when research should trigger.
- Changing the review flow, reviewer thresholds or role prompts as part of
  this work. Those changes come out of retros as proposals. The first retro,
  on job 001, will propose them.
- Retros on clean jobs.

## Anti-goals

The retro has failed, even if it technically works, if:

- it costs more than it saves: it must read selectively, and run once per job;
- fixes land without the user approving them, or agents rewrite their own
  prompts mid-run;
- it writes vague lessons ("be more careful", "test thoroughly") that no
  agent could act on;
- `AGENTS.md` or the role prompts grow without limit until agents ignore them.

## Design

### When it runs

A job is **due a retro** when it reaches `merged` or `dropped`, has no
`retro.md` yet, and any of these hold:

- `round - 1 > 0`, meaning more than one review round;
- `reworks > 0` or `respecs > 0`;
- any task has `runs > 1`;
- the folder has any `human-*.md`, `rework-*.md`, `autopilot-*.md` or
  `decision-round*.md`, or `decision.md` ever said `ESCALATE`.

A new script, `factory/bin/retro-due <job folder>`, encodes this check. It
exits 0 when the job is due and 1 when it isn't.

The orchestrator runs the check at the end of **Merge** (exit 0 path), after
`usage-record session`, and when a job is dropped. This includes headless
autopilot drains. A parked job (`needs-human`) gets no retro yet, because it
may still resume. It gets one when it reaches an end state.

`/factory retro <job-id>` runs one by hand at any stage, even if the job isn't
due, and on old jobs. Running it again replaces `retro.md` and reuses the open
retro PRs.

### The retro role

- New role file: `factory/agents/retro.md`.
- New `models.json` entry: `"retro": { "provider": "anthropic", "model": "sonnet" }`.
- It runs like any other anthropic role: through `factory-agent`, followed by
  `usage-record claude <job folder> retro`. Its own tokens therefore show up in
  the spend it is trying to cut.

**Reading budget.** Read in full:

- `job.json` and `usage.jsonl`;
- `spec.md` and `plan.json`;
- every `decision*.md`, `autopilot-*.md`, `human-*.md`, `human-brief-*.md` and
  `rework-*.md`;
- `build.md`.

For each `round-<N>/review-*.md`, read only the first line, `## Findings` and
`## Notes`. Open a whole review, build report or `.runs/` log only when it
explains an extra attempt. Read `AGENTS.md` and the earlier retros
(`factory/jobs/*/retro.md`) to check for repeats.

**It writes:**

1. `<job folder>/retro.md`. Its first line is `RETRO: <n> fixes` or
   `RETRO: nothing to change`, followed by:
   - `## Cost`: rounds, reworks, respecs, human decisions, builder reruns, and
     tokens per stage from `usage.jsonl` (`no usage data` for jobs from before
     PR #3).
   - `## What each extra attempt was for`: one line per extra round, rework,
     respec or rerun. Each line gives the cause, chosen from `spec`, `plan`,
     `build`, `review-signal` (the verdict didn't match the real problem),
     `review-batching` (findings found one at a time), `review-coverage` (a
     lens with nothing to review, or one that missed something), `environment`,
     `flaky`, `external-knowledge` or `owner-scope`. It also cites the file
     (and round) that shows it.
   - `## Fixes`: one entry per fix:
     - `kind`: `repo`, `factory` or `work`;
     - the target file;
     - what changes;
     - the evidence;
     - which earlier attempts it would have saved.
   - `## Repeats`: fixes that match a lesson in an earlier retro, or one
     already in `AGENTS.md` that agents ignored. A repeat is evidence that the
     earlier fix didn't work, so it should get stronger wording or a change of
     mechanism, not a duplicate.
   - `## Drafted beads`: one ready-to-run `bd create ...` line per `work` fix.
2. **`repo` fixes**, as edits in the retro worktree:
   - Only to `AGENTS.md` (or `CLAUDE.md`), or a doc that `AGENTS.md` tells
     agents to read for that area.
   - Lessons go under one `## Lessons from factory jobs` section, each 1–2
     lines and ending `(job <id>)`.
   - The retro keeps that section at about 30 lines or fewer. It merges or
     replaces old lessons instead of appending forever.
   - It never touches product code, tests, CI or config.
3. **`factory` fixes**, as edits in the factory-source worktree when one is
   configured (see below). The edits apply to the source tree's files:
   `factory/agents/*.md`, `.claude/skills/factory/SKILL.md`,
   `factory/models.json`, `factory/autopilot-policy.md`, `factory/bin/*` and
   `factory/AGENTS.template.md`. Without a source checkout, the role edits a
   scratch git copy of the installed factory files (`<job folder>/.retro-factory/`)
   instead, and `retro-publish` turns its diff into
   `<job folder>/retro-factory.patch`.

**Quality bar.** A fix is kept only if:

- it names the file it changes;
- an agent could act on it on its next job;
- it cites the attempt it would have saved.

Facts that only matter to this one job stay in `retro.md` and are not fixes.

### Landing the drafts

The orchestrator does every git and Beads write itself, as it already does for
other roles.

- **Repo PR.** Before running the role, the orchestrator creates a worktree on
  `factory/retro-<job-id>` from `<base>`. Afterwards, if the worktree has
  changes, it commits them. With `land: "pr"`, it also pushes, then opens the
  PR with `gh pr create --label factory-retro`. The PR title is
  `Retro <job-id>: <n> lessons` and the body is the `## Fixes` entries of kind
  `repo`. With `land: "local"`, it leaves the branch and names it in the
  report.
- **Factory PR.** This needs a new optional setting, `factory_source`, in
  `factory/settings.json` (and `settings.example.json`), holding the absolute
  path of a local ai-factory checkout. When it is set, the orchestrator does
  the same thing there:
  1. creates a worktree on `retro/<target-name>-<job-id>` from that checkout's
     `origin/main`;
  2. passes the path to the role;
  3. commits, pushes and opens a PR whose body is the `factory` fixes.

  Retro PRs on ai-factory always open as PRs, whatever the target repo's
  `land` setting.
- **Re-runs.** A re-run keeps what the user has already done with the first
  PR:
  - **Retro PR still open:** check out its existing branch and commit on top,
    so the user's edits survive. The retro replaces its own earlier lessons
    rather than adding to them.
  - **Retro PR merged:** start a new branch,
    `factory/retro-<job-id>-<k>`, from `<base>`. The lessons already in
    `AGENTS.md` count as existing, and are not re-proposed.
  - **Retro PR closed unmerged:** treat its fixes as rejected. Read the closed
    PR's body, and don't propose those fixes again. Any new fixes go on a new
    branch.

  The same rules apply to the factory PR.
- **Factory repeats across repos.** When `factory_source` is set, the role
  also reads ai-factory's `factory-retro` PRs, open and closed
  (`gh pr list --label factory-retro --state all --json title,body,state`).
  This lets it spot a factory problem already proposed from another repo. It
  then adds evidence to that open PR, as a comment the orchestrator posts,
  instead of opening a duplicate.
- **Stale installs.** A factory fix targets ai-factory's `origin/main`. When
  the target repo's installed copy differs from that source (the
  orchestrator runs `diff -rq` on the installed paths), `retro.md` says so.
  The report then tells the user to upgrade with `INSTALL.md`. The fallback
  `retro-factory.patch` is written against the installed copy and labelled as
  such in its first line.
- **No auto-merge.** Retro PRs never go through `factory/bin/land`. The user
  merges, edits or closes them.
- **Beads.** Drafted beads are not filed. They appear in `retro.md` and in the
  repo PR body, and the user runs the ones they want.
- **Cleanup.** The orchestrator removes the retro worktrees after the PRs are
  opened.
- **Report.** It gives one line per job: `retro <job-id>: <n> fixes, <repo PR url>, <factory PR url | patch path>`.

The extra prompt sentence for the role is:
`Retro worktree: <path>. Factory worktree: <path> (<source|installed>).`

### Seeing whether it helps

- `factory/bin/usage-summary` gains a trend line over the last 10 jobs that
  reached `merged`:
  `trend (last 10 merged): first-pass <x>/10, median rounds <r>, median reworks+respecs <w>, median tokens <t>M`.
  "First-pass" means `round == 1`, no reworks, respecs or human decisions, and
  no task with `runs > 1`. It is the inverse of `retro-due`.
  `/factory status` already prints `usage-summary`.
- The dashboard links `retro.md` and the retro PR on each job that has them.
  This requires `job.json` fields `retro_pr` and `retro_factory_pr`, set by
  `job-set`.

### Files touched

| File | Change |
| --- | --- |
| `factory/agents/retro.md` | new role |
| `factory/models.json` | `retro` entry |
| `factory/bin/retro-due` | new: the trigger check |
| `factory/bin/usage-summary` | trend line |
| `factory/bin/settings`, `factory/settings.example.json` | `factory_source` |
| `.claude/skills/factory/SKILL.md` | step table, **Retro** section, hooks in **Merge** and drop, `/factory retro <job-id>`, files list, `job.json` fields, skill description |
| `factory/dashboard.html` | retro links |
| `factory/test/*` | tests for `retro-due`, the trend line, the `factory_source` setting, and prose checks in the style of `prose.test.sh` |
| `README.md`, `INSTALL.md` | mention retros and `factory_source` |

## Acceptance

1. `retro-due` exits 0 for garmin-ai-coach jobs 001 and 002, and 1 for a
   fixture job that merged in one round with no reruns.
2. The retro is run on job 001 without touching garmin-ai-coach. The test
   repo is a throwaway git repo in the scratchpad (never committed): the
   current factory installed, garmin-ai-coach's `AGENTS.md`, copies of jobs
   001 and 002 in `factory/jobs/`, and `land: "local"`. In that repo,
   `/factory retro 001-event-bus-tenant-boundary` produces a `retro.md` that explains every one of the 8 rounds, and fixes
   covering at least causes 1–6 in **Why**:
   - the CDK and SQS lessons as `repo` fixes;
   - the batching, verdict, coverage and sandbox problems as `factory` fixes;
   - drafted beads for anything that isn't a doc or prompt edit.
3. In that test repo, the run leaves a `factory/retro-<job-id>` branch that
   touches only `AGENTS.md`. With `factory_source` unset, it also writes
   `retro-factory.patch`. Nothing merges.
4. The PR and re-run paths are covered by `factory/test/` with a stubbed `gh`,
   in the style of `land.test.sh`:
   - opening both PRs;
   - committing on top of an open PR;
   - starting a new branch after a merged PR;
   - skipping fixes from a closed PR;
   - commenting on a duplicate ai-factory PR.
5. `usage-summary` prints the trend line, and `factory/test/run` passes.
6. The real run in garmin-ai-coach is out of scope. It happens with Task 16's
   reinstall, which needs the user's go-ahead.

## Left to the builder

- The wording of `retro.md`'s role instructions, within the format above.
- How `retro-due` reads `decision.md` history (decision files are overwritten,
  so it may rely on `decision-round*.md`, `autopilot-*.md` and `human-*.md`
  being present).
- Where the dashboard shows the links.

## Calls made without the user

- The retro runs at `merged` or `dropped`, not at `needs-human`.
- The `sonnet` model, swappable in `models.json`.
- Repo fixes are limited to `AGENTS.md` and the docs it points at.
- Factory fixes go through a new `factory_source` setting, falling back to a
  patch file.
- Drafted beads are listed, not filed.
- `AGENTS.md` lessons are capped at about 30 lines.
- The trend window is the last 10 merged jobs.
- Re-runs commit on top of a retro PR that's still open, start a new branch
  after one is merged, and treat a closed PR as rejected.
- Repeats across repos are found through ai-factory's `factory-retro` PRs.
- A stale install is reported, not fixed.
