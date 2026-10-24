# Factory: Jev for the fast decisions

- Date: 2026-10-24
- Status: ready for review by the user
- Inputs: garmin-ai-coach jobs 001–004 (`~/Development/garmin-ai-coach/factory/jobs/`),
  `docs/findings/2026-10-19-token-efficiency-first-run.md`,
  `docs/superpowers/specs/2026-10-20-factory-retro-design.md`, MellowHarness's
  `JevBrain` (github.com/Mellow-Machines-Lab/MellowHarness,
  `Sources/MellowHarness/JevBrain.swift`) and TypeSafe's API docs
  (docs.typesafe.ai/api)

## Why

Jobs are slow and rarely right first time. The last two merged jobs on
garmin-ai-coach went `first-pass 0/2, median rounds 4.5`. Three causes show up
in the job folders:

1. **The model is fixed per role, not per task.** Every build task runs on
   `gpt-6-luna` at `xhigh`, from a 0.4M-token, one-minute task to a 4M-token,
   seven-minute one. Three of 17 tasks (`jo6q.1`, `jo6q.3`, `jz7l.1.1`) went
   BLOCKED on Luna and were redone on `gpt-6.1-sol`: 6.8M tokens and about 15
   minutes of cold starts that produced nothing. The owner is happy to spend a
   bigger model up front when it avoids that.
2. **A note takes the long way round.** In job 001 every reviewer said PASS in
   all 8 rounds (40 reviews). The real defects sat in the adversarial
   review's Notes, below `block_on`. Each one went approver → ESCALATE →
   autopilot at `xhigh` → REWORK → a new run, five times. The notes were real
   (the token-efficiency finding says so), so the fix is not to drop them but
   to send them straight to a fix task.
3. **Reviews with nothing to review.** UI and UX reviewed a docs-plus-test
   diff in all 8 rounds of job 001 ("No visual change"). Cheap in tokens, but
   each round waits for all five reviewers.

Every one of these is a quick multiple-choice judgement that today is either
hard-coded or made by an expensive reasoning model. TypeSafe's Jev is built
for exactly that: a hosted model that reads plain English and picks one of
your options in about 0.2–0.3 s, with a probability for each.

What the owner cares about, in order: **speed and accuracy** (fewer wasted
attempts and rounds), within the **weekly usage cap**. Sol uses the cap fast,
so it is spent when it is likely to save a failed attempt or a rework, not by
default.

## Goals

- Pick each build task's model and effort before it runs, so hard tasks start
  on Sol and easy ones run below `xhigh`.
- Turn a review Note that describes a real defect into a fix task in the same
  run, without the approver → autopilot round trip.
- Skip reviewers a change gives them nothing to review.
- Stay under the weekly cap: Sol choices stop when the cap is close.
- Log every Jev decision so retros can judge it and the owner can switch a
  decision point off.

## Non-goals

- The Claude side (orchestrator, spec-writer, planner on Opus). Jev doesn't
  change which Claude model runs or how much it reads.
- Learning. Jev doesn't train on outcomes; the factory gives it recent
  history as text, and humans tune the question files from retros.
- A shadow period. The owner chose to switch it straight on; the confidence
  floor and fallbacks below carry the risk instead.

## Anti-goals

It has failed, even if it technically works, if:

- Jev ever decides a merge, or a Note in an always-PARK category is handled
  without the approver;
- Jev being slow, down or unsure makes a job slower or worse than today;
- code, diffs, logs or secrets are sent to TypeSafe;
- it uses more of the weekly cap than it saves.

## Design

### The pieces

- **`factory/bin/jev`** — the one script that talks to TypeSafe, in bash and
  `jq` like the rest of `factory/bin/`. It takes a question file and a state
  file, `curl`s `POST https://api.typesafe.ai/v1/systemone` with the key from
  `JEV_KEY`, and prints the answers as JSON. It follows `JevBrain`'s rules:
  1.5 s deadline; one retry after 300 ms on 429, 5xx or a dropped connection,
  only if the deadline allows; an answer missing a question or picking an
  option it wasn't offered fails the whole call; on failure only the HTTP
  status is logged, never the body. Any failure exits non-zero and the caller
  falls back.
- **`factory/jev/<decision>.json`** — one question file per decision point,
  holding the questions, options and each option's `what` and optional
  `not_for`, in the request shape `JevBrain.body` builds. Tuning a decision
  means editing its file.
- **`factory/jobs/<job-id>/jev.jsonl`** — one line per call: decision point,
  the exact state sent, the answers and probabilities, latency, whether the
  answer was used or why not (`low-confidence`, `cap`, `guardrail`, `error`),
  and what the factory did.
- **`factory/settings.json`** gains:

  ```json
  "jev": {
    "send": "off",
    "route": true, "triage": true, "reviewers": true,
    "min_confidence": 0.7,
    "sol_ceiling": 0.8,
    "park_paths": ["**/.env*", "**/*secret*", "..."],
    "model": "jev-latest"
  }
  ```

  `send` is `off` (the default: Jev is never called), `metadata` or
  `summary`. Each decision point can be switched off on its own.

### What Jev is sent

Never code, diffs, logs, command output or environment files. The
orchestrator writes the state as a few plain-English lines, like
MellowHarness's HISTORY and NOW, so a small model reads it well and it stays
under about 3k tokens.

- **`metadata`**: file paths, line counts, labels, round number, task runs,
  and outcome counts from history.
- **`summary`**: adds the task's title and description from `plan.json` and
  the text of the Note being triaged.

Before sending, the state is redacted: anything that looks like a key,
token, email address or URL with credentials is replaced with `[redacted]`.
The default is `summary` for personal repos like garmin-ai-coach and
`metadata` elsewhere; each repo sets its own.

TypeSafe's docs don't say how long requests are kept or whether they train
on them. Check their terms before using `summary` on anything sensitive.

### Decision 1: route (before each build task)

**When:** build step 2, before the model is picked, for every task's first
run. A second run after BLOCKED goes to `builder-escalation` as today; Jev
isn't asked.

**State:** the task (title, description in `summary`, files it names, label
`fix`/`final`), the job's round, and history: how earlier tasks in this repo
that touched the same top-level directories went (which model, which effort,
whether they went BLOCKED), read from `factory/jobs/*/usage.jsonl` and
`job.json`.

**Question** `route`, options are tiers, not model names:

| Option | Means | Role key it runs as |
|---|---|---|
| `light` | Mechanical: a rename, a config value, a doc edit, one small test | `builder-light` |
| `standard` | Ordinary: clear change in a few files with an obvious test | `builder-standard` |
| `thorough` | Fiddly: several files, edge cases, or unfamiliar code | `builder` (today's default) |
| `strong` | Likely to defeat the default builder: hard reasoning, a past BLOCKED in the same area, cross-cutting change | `builder-escalation` |

Every preset gains `builder-light` and `builder-standard`, so route works
whatever the preset, and models are still only named in `models.json`
(`run-codex` and `usage-record` keep reading model and effort from the role
key). Starting values *(my call)*:

| Preset | `builder-light` | `builder-standard` |
|---|---|---|
| `mixed`, `openai` | Luna `medium` | Luna `high` |
| `lean` | Luna `medium` | Luna `high` (= its `builder`) |
| `claude` | Sonnet | Sonnet |

A hand-edited `models.json` without the two keys falls back to `builder`
for them.

**Used when** the top option's probability is at least `min_confidence`.
Otherwise the task runs as today, on `builder`.

**The cap:** `strong` is used only while the account's weekly Codex usage is
under `sol_ceiling` (a fraction; the recorded `used_percent` is 0–100, so
compare against `sol_ceiling × 100`). The usage comes from the newest
rollout's `rate_limits.primary` under `${CODEX_SESSIONS_DIR:-~/.codex/sessions}`
— account-wide, across jobs and repos, the same place `usage-record` reads it
*(my call; a per-job read would give every new job's first tasks Sol)*. At or
over the ceiling, `strong` runs as `thorough`, logged as `cap`. With no
rollout found, `strong` is allowed. When `builder-escalation` is not an
OpenAI role (the `claude` preset), the cap check is skipped.

**Effect:** the orchestrator runs the task as the chosen role key and records
it in `job.json`'s task entry. A BLOCKED second run still goes to
`builder-escalation`; a task routed `strong` that goes BLOCKED gets its
second run there too, then `build-blocked` as today. Tasks today's rule
already sends to `builder-escalation` (second runs, and fix tasks in a run's
last round) are not routed *(my call)*.

### Decision 2: triage (after an all-PASS round, before the approver)

**When:** a review round ends with every verdict PASS and at least one Note
across the reviews.

**State, per Note:** the reviewer, its severity and confidence (adversarial
gives both), the file path, the Note text in `summary`, and whether earlier
rounds raised a Note on the same path.

**In `metadata` mode** Jev can't read the Note, so it only answers `fine` or
`approver`: `fine` settles the Note, `approver` leaves it for the approver as
today. Jev never starts a fix round or files a bead on a Note it hasn't read
*(my call)*.

**Question per Note** `note.<n>`:

| Option | Means |
|---|---|
| `fix-now` | A real defect against the spec or acceptance criteria; the approver would escalate on it |
| `follow-up` | Real but outside this job's spec; worth a bead, not a round |
| `fine` | Style, preference, or already handled |

**Guardrails:** these Notes are never sent to Jev and go to the approver as
today *(my call: mechanical, so the orchestrator still makes no judgement of
its own)*:

- every Note from `reviewer-security`;
- a Note whose path matches a glob in `jev.park_paths` in
  `factory/settings.json`. The default covers the Always PARK categories:
  `**/.env*`, `**/*secret*`, `**/auth/**`, `**/migrations/**`,
  `.github/**`, `**/*.tf`, `infra/**`, `**/cdk*/**`,
  `**/Dockerfile*`, `**/package.json`, `**/*.lock`. Each repo extends it.

Triage runs only while `N - round_base < MAX_ROUNDS`. A Note whose answer is
below `min_confidence` is left for the approver.

**Effect:**

- Any `fix-now`: the orchestrator files `Fix round N notes` (listing those
  Notes) plus the usual verify task, exactly like a CHANGES round, and goes
  to **Build** — no approver, no autopilot. This counts as a round.
- `follow-up`: filed as a queued `feature` bead, label `factory,queued`,
  linked to the job's bead, its description quoting the Note.
- Everything triaged is listed in a new `round-<N>/triage.md`. The approver
  reads it: `fine` and `follow-up` Notes are settled and not a reason to
  escalate by themselves; untriaged Notes are judged as today.

### Decision 3: reviewers (before each review round)

**When:** review step 2, before the reviewers start.

**State:** the files the round's diff touches (paths and line counts only, in
both modes), whether any are UI (from the repo's file types and the UX/UI
roles' existing "visual change" rule), the round number, and for round 2 on,
which reviews raised Findings or Notes in the round before and what the fix
tasks changed.

**Questions** `review.ux`, `review.ui`, and from round 2 on `review.security`
and `review.code`, each `run` or `skip`. `reviewer-adversarial` always runs.
In a run's first round, `security` and `code` always run.

**Effect:** a skipped reviewer gets a file written by the orchestrator,
`round-<N>/review-<lens>.md`, reading `VERDICT: SKIPPED`, a blank line, then
`Skipped by Jev (p=<p>): <the state line that decided it>.` The round is done
when every review file exists. The approver, autopilot and briefer treat
`SKIPPED` as "not reviewed this round", which is not a reason to escalate.

### How we know it works

`usage-summary`'s trend line and the retro gain:

- per decision point: calls, how often the answer was used, fallbacks by
  reason;
- route: share of tasks on Sol, and how often a routed task still went
  BLOCKED (by option);
- triage: `fix-now` Notes whose fix round found nothing to do, and
  `fine`/`follow-up` Notes the approver escalated on anyway;
- the job's share of the weekly cap.

Success is first-pass rate and median rounds improving over the next ten
jobs, with weekly cap use no higher than before.

## Calls made for the owner (check these)

- `min_confidence` 0.7 and `sol_ceiling` 0.8 as starting values.
- Route options are tiers mapped to new role keys in every preset, not
  model names; the tier models in the table above.
- The cap reads the account-wide Codex quota, not the job's.
- In `metadata` mode triage only clears `fine` Notes; it never starts a fix
  round.
- Security-reviewer Notes and `park_paths` matches are never triaged. Note
  that garmin-ai-coach's job 001 Notes were on `infra/` and `docs/` paths:
  with this default the infra test Notes would still go to the approver.
- Triage `fix-now` skips the approver and autopilot. That changes today's
  rule that only CHANGES verdicts start a fix round.
- `reviewer-adversarial` always runs, and `security`/`code` always run in a
  run's first round.
- A new `VERDICT: SKIPPED`.
- Jev's own spend (TypeSafe input tokens; output is currently free) is not
  counted against the weekly cap or logged in `usage.jsonl`, only in
  `jev.jsonl`.

## Left to the builder

- How the state lines are worded, as long as they follow the rules above.
- The redaction patterns.
- How history is summarised for routing.
- Tests: follow `factory/test/` (shell tests with fixtures), with a fake
  `curl` the way `run-codex.test.sh` fakes `codex`.
