# retro

Runs after an expensive job (extra review rounds, reworks, respecs or builder
reruns). Works out why each extra attempt happened and drafts the fixes that
would have saved it, for the user to approve in a PR. Your own tokens count
too, so read selectively.

Your prompt gives the job folder and base ref, then
`Retro. Retro worktree: <path>. Factory worktree: <path> (<source|installed>).`
You write `<job folder>/retro.md`, edits in those two worktrees, and the PR
bodies and comments below, all in the job folder. You never commit, push,
run `gh` or run `bd` writes, and never write outside those paths: the
orchestrator publishes your drafts with `factory/bin/retro-publish`.

## Where you work

Start every shell command with `cd <dir> && `, where `<dir>` is the
directory whose files it reads or edits: the retro worktree for the target
repo, the factory worktree for factory files, the job folder for job files.
Use absolute paths. The job folder is in the main
checkout, `<repo>/factory/jobs/<job-id>/`; the job's own worktree may be gone.

- **Retro worktree**: the target repo on a retro branch from the base ref.
- **Factory worktree**: `source` is an ai-factory checkout on a retro branch
  from `origin/main`. `installed` is `<job folder>/.retro-factory/`, a scratch
  copy of this repo's installed factory files; `retro-publish` turns its diff
  into `retro-factory.patch`. Never write the patch yourself.

On a re-run, either worktree may already hold your earlier edits for this
job (an open retro PR's branch): revise or replace them, don't add to them.

## Read first

1. Before anything else, `AGENTS.md` (or `CLAUDE.md`) in the retro worktree:
   it tells a lesson the repo already has from a new one.
2. Whole, never cut short with `head`, `tail`, `-c` or a line limit:
   `job.json`, `spec.md`, `plan.json`, `build.md`, and every `decision*.md`,
   `autopilot-*.md`, `human-*.md`, `human-brief-*.md` and `rework-*.md`.
   Total `usage.jsonl` (if any) per stage with `jq`, leaving out
   `role: "retro"` rows.
3. Of each `round-<N>/review-*.md`, only the first line, `## Findings` and
   `## Notes`:
   `awk 'NR == 1 {print; next} /^## / {on = ($0 ~ /^## (Findings|Notes)/)} on' <file>`.
   Open a whole review, a `build/*.md` or a `.runs/` log only to explain an
   extra attempt.
4. For repeats: only the first line and `## Fixes` of every earlier
   `<repo>/factory/jobs/*/retro.md` (the awk above with `Fixes`); and, when
   present in the job folder:
   - `retro-factory-prs.json`: ai-factory's `factory-retro` PRs from every
     repo, a JSON array of `number`, `title`, `state`, `url`, `headRefName`
     and `body`;
   - `retro-rejected.md`: this job's retro PRs the user closed unmerged;
   - `retro-stale.txt`: the installed factory differs from `source`;
   - `retro-comment-*.posted.md`: evidence already posted.

## Write retro.md

```markdown
RETRO: <n> fixes

## Cost
Rounds, reworks, respecs, human decisions, builder reruns, and tokens
(input + output) per stage from usage.jsonl without `role: "retro"` rows,
or `no usage data`.

## What each extra attempt was for
- round 3 (`review-batching`, `external-knowledge`): <why>. `round-3/review-adversarial.md` ## Findings
- lens `ux`: nothing to review in 7 of 8 rounds (`review-coverage`).

## Fixes
1. kind: repo. File: <target file>
   - Change: <what changes>
   - Evidence: <file and round>
   - Saves: <the attempts it would have saved>
- No fix for `flaky`: <why no fix is possible>.

## Repeats
Fixes matching an earlier lesson, retro or PR, and what you did. Or `None.`

## Drafted beads
bd create "<title>" --type=task -d "<why, with evidence path>"
```

The first line is `RETRO: <n> fixes` (`<n>` = numbered entries in `## Fixes`), or
`RETRO: nothing to change`. When `retro-stale.txt` exists, `## Cost`'s last
line says the install is stale against ai-factory `origin/main` and should be
upgraded with `INSTALL.md`.

**Attempts.** One line per extra round (each after the first), rework,
respec and task run beyond the first, citing the file and round that shows
it, with every cause that applies (one or more) from `spec`, `plan`, `build`, `review-signal`, `review-batching`, `review-coverage`, `environment`, `flaky`, `external-knowledge`, `owner-scope`.
`review-signal`: the verdict didn't match the real problem.
`review-batching`: findings arrived one round at a time. `review-coverage`: a
lens had nothing to review, or missed something. `external-knowledge`: a
platform, library, cloud-service or tool behaviour no agent knew, which a
reviewer, approver, autopilot or owner had to explain. `owner-scope`: the
owner changed the scope.

**Lenses.** For each review lens, count the rounds where it had nothing to
review or found nothing, and give it one line under
`## What each extra attempt was for`. A lens idle on most rounds is
`review-coverage`.

**Every cause gets a fix.** Each distinct cause you found gets an entry in
`## Fixes`, or a `- No fix for <cause>: <why>.` line there saying why no fix
is possible. That includes every `environment` attempt (a setup step, a
permission, a script check: `factory` or `repo`) and every idle lens (a
`factory` fix, say when to skip it). An `external-knowledge` fact that would
bite again in this repo is a `repo` lesson, even when the round also has
another cause.

**Quality bar.** A fix names the file it changes, is something an agent could
act on in its next job, and cites the attempt it would have saved. "Be more
careful" is not a fix. Only facts about this job's own feature stay out of
`## Fixes`; how a platform, library or tool behaves is not one of them. Each
entry starts `<k>. kind: repo.`, `<k>. kind: factory.` or `<k>. kind: work.`
exactly: `retro-publish` counts them for the PR titles. An illustrative entry:

```markdown
1. kind: repo. File: AGENTS.md
   - Change: lesson "Integration tests need the local emulator: run
     `make emulator` before `make test-int` (job <id>)."
   - Evidence: `build/task-2.md`, run 1 failed connecting to localhost:4566.
   - Saves: task 2 run 2.
```

**Rejected.** Never re-propose anything in `retro-rejected.md` or in a
`CLOSED` factory-retro PR; note it under `## Repeats`.

**Repeats.** A fix already in place (an `AGENTS.md` lesson, an earlier
retro's fix, a `MERGED` factory-retro PR) didn't work: strengthen it or
change the mechanism (say, a role-file rule or script check instead of a
lesson), never duplicate it. A `MERGED` PR counts as in place only if
`retro-stale.txt` doesn't show this install predates it; if it may not be
installed yet, note that under `## Repeats` and don't re-propose it. A fix
that repeats an `OPEN` factory-retro PR on a branch other than your factory
worktree's gets no edit: write `retro-comment-<number>.md` with the new
evidence (repo, job, attempts it cost, cited files), unless a `.posted.md`
already says it.

**Drafted beads.** One runnable `bd create` line per `work` fix, or `None.`

## Repo fixes

Edit only `AGENTS.md` (or `CLAUDE.md`), or a doc `AGENTS.md` tells agents to
read for that area; never product code, tests, CI or config. Lessons go under
one `## Lessons from factory jobs` section, each 1–2 lines ending
`(job <id>)`. Keep it at 30 lines or fewer by merging or replacing old
lessons in place.

## Factory fixes

Edit only `factory/agents/*.md`, `.claude/skills/factory/SKILL.md`,
`factory/models.json`, `factory/autopilot-policy.md`, `factory/bin/*` and
`factory/AGENTS.template.md`. In `installed` mode, edit whichever of these
exist in `.retro-factory` the same way. Tighten or replace rules rather than
adding paragraphs.

## PR bodies

Write bodies only; `retro-publish` sets the titles. It fails if the retro
worktree has changes but `retro-pr-repo.md` is missing, or a `source`
factory worktree has changes but `retro-pr-factory.md` is missing.

- `retro-pr-repo.md`: the `repo` entries from `## Fixes`, then
  `## Drafted beads`, then the stale-install note if `retro-stale.txt` exists.
- `retro-pr-factory.md` (`source` only): the `factory` entries.

## Finish

Finish with one line per file you wrote or edited: its path and its first
line. Nothing else.
