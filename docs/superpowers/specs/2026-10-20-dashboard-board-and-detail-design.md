# Dashboard: lane board and job detail

- Date: 2026-10-20
- Status: ready for review by the user
- Inputs: the user's two reference images (`ui-design/original-0f3a8e2e….webp`,
  a kanban with a right-hand detail drawer; `ui-design/ef70241a….webp`, a node
  canvas with an inspector), the dashboard as of PR #6 (`factory/bin/dashboard`,
  `factory/dashboard.html`), the PR #3 dashboard (`git show 4ee32e8~1:factory/dashboard.html`,
  screenshot `.superpowers/sdd/2026-10-19-factory-parallel-spend-review/task-10-dashboard-fix.png`),
  and garmin-ai-coach jobs `001-event-bus-tenant-boundary` and
  `002-eval-gate-blocking` as real data. Brainstorm mockups:
  `.superpowers/brainstorm/9319-1792487353/content/` (`layout.html`,
  `running-lane.html`, `detail.html`).

## Why

The user watches factory jobs to see three things per job: where it is in
spec → plan → build → review → approve, what each stage produced, and what it
cost in tokens (spend is plan quota, so cost is for visibility only). They
liked the information the PR #3 dashboard gave, but its layout read as
AI-generated, and its job drawer was hard to make sense of: it was a flat list
of files (`spec.md`, `rework-4.md`, `round-6/review-code.md`, …), so the reader
had to reconstruct the story. Job 001 has 40-odd files across 8 review rounds
and 6 rework cycles.

What the user reads when they open a job: **the plan and the acceptance
criteria**, then the output of each agent, the **prompt** that agent was given,
and **what changed in the code**.

Later the user wants full traceability (PRD → requirement → job → task →
commit). That is not built now, but this design must not block it.

## Goals

1. A board with four lanes grouped by what the owner has to do, with the
   Running lane split into stage sections.
2. A job detail view that tells a job's story: acceptance criteria next to the
   agent runs in order, with prompt, output and code changes per run.
3. Code diffs shown in the dashboard, per task commit and for the whole job.
4. Prompts recorded for every agent run, Claude ones included.
5. No information the PR #3 dashboard showed is lost (quota meters, land mode,
   spend summary, runaway flags, task dots, review verdicts per round,
   the job's files).
6. A look that is calm, specific and not AI-template (see **Visual direction**).

## Non-goals

- The Trace view (node canvas). Described under **Later: Trace**; not built.
- Any write action from the dashboard. It stays read-only; commands like
  `/factory approve` are still typed in Claude Code.
- Dollar cost. Tokens only.
- New dependencies or a build step. It stays one HTML file plus a Node server
  using built-in modules only.

## Anti-goals

- Glows, gradients, glass, grid backgrounds, sparkle icons, pill everything,
  uppercase wide-tracked labels, or decoration without a stated reason.
- A detail view that is still a file list with nicer styling.
- Losing data the old dashboard had because the new layout has no slot for it.
- The server running anything that can write: no `git` command other than
  read-only ones, no shell interpolation.

## Design

### Board

Four lanes, left to right. A job's `stage` decides its lane:

| Lane | Stages | Notes |
|---|---|---|
| Running | `spec`, `plan`, `build`, `review` | split into four labelled sections in that order; an empty section shows "none" so the lane keeps its shape |
| Deciding | `approve`, `autopilot` | card shows which (marker) |
| Needs you | `needs-human`, `resubmitted` | card shows `situation` in plain words |
| Done | `merged`, `dropped` | newest first; the 10 most recent shown, then "Show all N" |

Cards (all stages): job number, bead id, feature title (two lines max), total
tokens. Then by stage:

- **spec / plan**: the model from `models.json` and what it is producing
  (`spec.md`, the plan).
- **build**: the model, "task k of n", and one dot per task (closed, running,
  open, blocked).
- **review**: "round N" and one box per reviewer (sec, code, ux, ui, adv) for
  the current round: pass, changes, or dashed while pending.
- **approve / autopilot / needs-human / resubmitted**: the marker, and the last
  round's result.
- **merged / dropped**: outcome, task count, PR link if any.

A runaway flag (from the old dashboard's `runawayFlags`) shows on the card.

Header: product name as text ("Factory"), Codex quota meters (weekly and 5h,
as the old dashboard computes them from usage records), land mode, the
spend summary (collapsible, as before), a light/dark toggle, and the time of
the last refresh. The board keeps polling `/api/state` while the detail is open.

### Job detail

Clicking a card (or Enter on a focused card) opens the detail on the right; the
board stays visible beside it. An expand control widens it to the full window
(needed for diffs). Escape or the close button closes it. The open job id goes
in the URL hash so a reload or a shared link reopens it.

**Header**: job id, bead, branch, stage, round count, task count, total tokens
and runs, PR link when there is one, and the job's total change ("2 files,
+184 −3"), which opens the combined diff.

**Left column: acceptance criteria.** The numbered list under
`## Acceptance criteria` in `spec.md`, verbatim and rendered as markdown. Under
each criterion: the task ids whose `covers` in `plan.json` include its number,
each with its status from `job.json`. Below: the spec's `## Out of scope`,
collapsed. If `spec.md` doesn't exist yet or has no such section, say so.

**Right column: agent runs, in order.** Grouped into stages:

1. Spec, 2. Plan (shows each task with its `covers`), 3. Build (one row per
   task), 4. each review round (one row per reviewer), 5. rework and
   autopilot/owner decisions between rounds, 6. Approve, 7. Merge.

When a job has more than two review rounds, the cycles between the first and
last round fold into one line ("Rework cycles 1 to 6 (rounds 2 to 7)") that
expands in place.

Each run row shows role, model, tokens (from `usage.jsonl` where a record
matches) and time, and up to three collapsible sections, all closed by
default:

- **Prompt**: the run's `.runs/<ts>-<key>.prompt.md`. If none was recorded
  (Claude runs in jobs before this change), show "No prompt recorded for this
  run".
- **Output**: the file that run produced, rendered as markdown: `spec.md`,
  `plan.json` as a task list, `build/<task-id>.md`, `round-N/review-<k>.md`,
  `decision*.md`, `autopilot-<k>.md`, `rework-<k>.md`, `human-<k>.md`. For
  Codex runs without such a file, `.runs/<ts>-<key>.last.md`.
- **Changes** (build runs only): files touched by the task's commit with
  lines added/removed; each file expands to its unified diff.

A "Files" toggle in the header still lists every servable file in the job
folder, as the old drawer did, for anything the run view doesn't place.

### Code changes

The factory commits each task once, with the task id in the message, e.g.
`test: reject broad IAM actions on feedback extraction role (garmin-ai-coach-903.1)`.
The merged job lands as one commit `<bead>: <feature> (#<pr>)`.

- **Per task**: the commit on the job's branch (or in history after merge)
  whose message ends with `(<task-id>)`.
- **Whole job**: before merge, `git diff <base>...<branch>`; after merge, the
  landing commit's diff.

The repo is the folder containing `factory/` (`path.resolve(factory, '..')`).

Merge deletes the job branch (`git branch -D factory/<job-id>`) and the job
lands squashed, so task commits are otherwise lost once the remote branch is
pruned and `git gc` runs. Agreed with the user: at **Merge** in SKILL.md, just
before the branch is deleted, run
`git update-ref refs/factory/jobs/<job-id> factory/<job-id>`. This is a local
ref, never pushed. The server looks task commits up from the branch while it
exists, otherwise from `refs/factory/jobs/<job-id>`. If neither exists (an old
job), Changes says "Task commits are no longer available for this job" and
the whole-job diff still works.

One-off, during this work: create `refs/factory/jobs/001-event-bus-tenant-boundary`
and `refs/factory/jobs/002-eval-gate-blocking` in garmin-ai-coach from their
`origin/factory/…` branches while those still exist.

### Server changes (`factory/bin/dashboard`)

- Serve `.runs/*.prompt.md` and `.runs/*.last.md` only. `.jsonl`, `.stderr`,
  `.json` and logs stay unserved.
- New read-only endpoints for runs (the list of `.runs` prompt/output pairs
  with timestamp and key), a task's commit (stat + diff), and the job's diff.
- `git` is run with `execFile` (no shell), with fixed subcommands
  (`log`, `show`, `diff`), `--no-ext-diff --no-color`, and arguments validated
  (task ids against the job's `tasks`, commit hashes as hex). Output is capped
  (e.g. 2 MB); a diff over the cap says it was truncated.
- Still 127.0.0.1 only, GET only.
- Token fallback: when a job has no `usage.jsonl` (both garmin-ai-coach jobs,
  which predate usage recording), the server reads token counts from the
  `turn.completed` events in `.runs/*.jsonl` and returns them in the same shape
  as usage records, marked as derived. Those files are still never served.
  Runs with no source show "tokens not recorded" rather than 0.

### Factory change: record Claude prompts

In `.claude/skills/factory/SKILL.md`, **Running a role → anthropic**: before
spawning `factory-agent`, write the prompt to
`<job folder>/.runs/<UTC yyyymmdd-HHMMSS>-<key>.prompt.md`, the same naming
`run-codex` uses. Skip it for the importer (no job folder). Add a small helper
in `factory/bin/` if that keeps the orchestrator's step to one command.

The file holds what the agent effectively reads, in the same shape as
`run-codex`'s prompt files: the role file's contents, then the one-line prompt
sent to the subagent. (The subagent itself only receives the line, which
points at the role file; a pointer alone isn't useful to read.)

`factory/bin/run-adversarial` also saves the focus prompt it builds to
`.runs/<ts>-reviewer-adversarial.prompt.md`, so every role has a prompt.

### Visual direction

Agreed with the user, from their first reference image:

- Light theme by default: white cards on a pale grey board. A working dark
  theme behind a toggle; both checked for contrast.
- One accent colour (a blue) for the selected card and the current stage only.
- Status colours: green for pass/done, amber for waiting/pending, red for
  changes/blocked. No other colour.
- No glows, gradients, glass, grid backgrounds or decorative icons. Radius
  small and consistent; shadow only on the open detail (it sits above the
  board).
- System UI font for text, chosen for reading long spec and diff text;
  monospace only for ids, branches, prompts and diffs.
- Motion: the detail opening and sections expanding, plus a slow pulse on the
  stage section that has a running job. Nothing else moves.
- Dials (antislop): ENERGY 1 / RHYTHM 2 / MOTION 1. Apply antislop rules while
  building and run its Delivery Gate before calling it done.

### States

- Loading: first fetch of `/api/state`, and each lazy section (prompt, output,
  diff) while it loads.
- Empty: no jobs ("No jobs yet. Start one with `/factory <feature>`"); empty
  sections in lanes; missing prompt/output/commit.
- Error: server unreachable (keep the last board, mark it stale with the time);
  `problems` from `/api/state` (e.g. a broken `job.json`) listed in the
  header; a section that fails to load says why.

### Access

Every card, section toggle and control is a real button reachable by Tab, with
a visible focus ring; Enter/Space toggles; Escape closes the detail. Under
about 900px wide the lanes stack and the detail takes the full screen. No
horizontal page scroll; diffs scroll inside their own box.

## Later: Trace

Not built now. Recorded so the next design starts here.

**What it is**: a canvas (like the second reference image) where every
artefact is a node and links show where it came from: PRD → requirement →
bead → job → spec → task → commit, plus review rounds and decisions. Clicking
a node opens the same detail panel as the board. It answers "which job
delivered this requirement?" and "which PRD is this commit for?".

**What exists today**: job → bead (`job.json.bead`), job → tasks
(`job.json.tasks`), task → acceptance criteria (`plan.json` `covers`), task →
commit (task id in the commit message), job → PR (`job.json.pr`).

**Dependencies, in order**:

1. `/factory import <prd>` records, on each bead it creates, the PRD path and
   the requirement id it came from (bead metadata or a field Beads already
   has).
2. PRDs carry stable requirement ids the importer can cite.
3. Acceptance criteria get ids that survive respecs (today they are list
   numbers in `spec.md`, which can renumber).
4. A server endpoint that assembles the graph across jobs (one PRD can feed
   several jobs).

## Acceptance

1. `factory/bin/dashboard` serves the new page; `factory/test/dashboard.test.sh`
   passes, with new cases for: `.runs/*.prompt.md` and `.last.md` served,
   `.runs/*.jsonl` and `.stderr` refused, task commit and job diff endpoints
   on a test git repo, a bad task id or hash refused, path traversal refused.
2. All existing factory tests still pass.
3. With the garmin-ai-coach job folders copied into a test factory, the board
   puts 001 and 002 in Done, and job 001's detail shows its 7 acceptance
   criteria with covering tasks, its runs in order with rounds 2 to 7 folded,
   prompts for the Codex runs, and the diff of commit `07efd776` under task
   903.1.
4. A run of a Claude role after the SKILL.md change leaves a
   `.runs/<ts>-<key>.prompt.md` (role file plus the line sent), a
   `run-adversarial` run leaves its prompt, and the detail shows both.
4a. A test merge leaves `refs/factory/jobs/<job-id>`, and after the branch is
   deleted the detail still shows each task's diff.
5. Both themes, keyboard-only use, and a 390px-wide window checked in a
   browser, with screenshots. The antislop Delivery Gate reported with no
   FAIL.

## Left to the builder

- How runs are matched to stages, rounds and tasks (timestamps in `.runs`
  names, `usage.jsonl` `stage`/`round`, task ids in prompts).
- The base branch for an unmerged job's diff (main, or whatever `land` uses).
- How the landing commit of a merged job is found (PR number from
  `job.json.pr`, or the `<bead>:` commit subject).
- Endpoint names and response shapes.
- Exact colours, spacing and type sizes within the visual direction.

## Calls made without the user

- Done lane shows the 10 most recent jobs, then "Show all".
- Detail opens beside the board, with expand to full width, rather than as a
  separate page.
- The open job is kept in the URL hash.
- The board keeps polling while the detail is open.
- Only `.prompt.md` and `.last.md` from `.runs/` are served; raw logs stay
  private.
- Diffs are rendered by the page itself (no diff library).
- Claude prompt files hold the role file plus the line sent, matching Codex
  prompt files.
- `run-adversarial` saves its prompt too.
- Tokens fall back to Codex `.runs/*.jsonl` for jobs without `usage.jsonl`.
- A "Files" list stays in the detail as a fallback.
- Implementation is done by gpt-6-luna through Codex, per the user's
  instruction; Claude does the design, planning and review.
