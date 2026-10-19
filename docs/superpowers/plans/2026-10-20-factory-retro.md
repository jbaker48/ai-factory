# Factory Retro Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After an expensive job, a `retro` role works out why each extra attempt happened and drafts fixes. Fixes are `AGENTS.md` lessons in a target-repo PR, factory changes in an ai-factory PR (or a patch), and drafted beads. The user approves each one. `usage-summary` shows whether jobs are getting cheaper.

**Architecture:** Three new bash scripts do all the mechanical work, so the orchestrator stays a router:
- `retro-due`: is this job due a retro?
- `retro-prep`: set up the worktrees and context files.
- `retro-publish`: commit, push, open or update PRs, post comments, clean up.

The judgment lives in one role file, `factory/agents/retro.md`, run on `sonnet` through `factory-agent`. `SKILL.md` calls these at the end of **Merge** and **DROP**, and from a new `/factory retro <job-id>`.

**Tech Stack:**
- bash, with `set -uo pipefail` as in `factory/bin/*`
- jq, git worktrees, the `gh` CLI
- the factory's own test harness (`factory/test/lib.sh`, `factory/test/run`)

**Spec:** `docs/superpowers/specs/2026-10-20-factory-retro-design.md`

## Global Constraints

- Retro PRs never go through `factory/bin/land`, and nothing merges them. The user merges, edits or closes them.
- A retro never changes a job's `stage` or `situation`. A retro failure is reported, and the job stays where it was.
- Target-repo edits: only `AGENTS.md`/`CLAUDE.md` or a doc `AGENTS.md` tells agents to read, under `## Lessons from factory jobs`, kept to about 30 lines or fewer, with each lesson ending `(job <id>)`.
- Factory edits: only `factory/agents/*.md`, `.claude/skills/factory/SKILL.md`, `factory/models.json`, `factory/autopilot-policy.md`, `factory/bin/*` and `factory/AGENTS.template.md`.
- PR label `factory-retro`. Repo branch `factory/retro-<job-id>[-<k>]`. Factory branch `retro/<target-name>-<job-id>[-<k>]`. Repo PR title `Retro <job-id>: <n> lessons`.
- `retro.md` first line is exactly `RETRO: <n> fixes` or `RETRO: nothing to change`.
- Causes are exactly: `spec`, `plan`, `build`, `review-signal`, `review-batching`, `review-coverage`, `environment`, `flaky`, `external-knowledge`, `owner-scope`.
- `models.json`: `"retro": { "provider": "anthropic", "model": "sonnet" }`.
- Setting `factory_source`: an optional absolute path to a local ai-factory checkout.
- Trend line: `trend (last <n> merged): first-pass <x>/<n>, median rounds <r>, median reworks+respecs <w>, median tokens <t>M`.
- Scripts follow the house style: a header comment with usage and exit codes, they print nothing they don't need to, they change `job.json` only through `factory/bin/job-set`, and they pass `-q` to git.

## Review Focus

1. **A retro that fails after a merge.** The job must stay `merged`, and a headless drain must go on to the next job. Pinned by the prose test in Task 6 (`Retro never changes stage`).
2. **Old job folders** (from before PR #3: no `usage.jsonl`, `rework-*.md` and `decision-round1.md` present). `retro-due` must still fire, and the trend line must print `median tokens n/a`. Pinned in Tasks 1 and 2.
3. **A repo that has never had a `factory-retro` label.** `gh pr create --label` fails unless the label exists, so `retro-publish` must create it first. Pinned in Task 4 (`test_label_created_before_pr`).
4. **A crashed earlier run left the retro worktree behind.** `retro-prep` must replace it, not fail. Pinned in Task 3 (`test_stale_worktree_replaced`).
5. **A re-run after a retro with nothing to change, or a re-run that would repeat comments.** There must be no empty commit, no empty PR, and no comment posted twice. Pinned in Task 4 (`test_nothing_to_change`, `test_comment_posted_once`).

---

### Task 1: `retro-due`

**Files:**
- Create: `factory/bin/retro-due`
- Test: `factory/test/retro-due.test.sh`

**Interfaces:**
- Produces: `factory/bin/retro-due <job folder>`, which prints nothing.
  - Exit codes: 0 = due, 1 = not due, 2 = usage error or unreadable `job.json`.
  - A job is due when all of these hold:
    - `stage` is `merged` or `dropped`;
    - there is no `retro.md`;
    - at least one of:
      - `round > 1`;
      - `reworks > 0` or `respecs > 0`;
      - any `tasks[].runs > 1`;
      - any `human-*.md`, `rework-*.md`, `autopilot-*.md` or `decision-round*.md` exists;
      - the first line of `decision.md` is `ESCALATE`.

- [ ] **Step 1: Write the failing tests.** Follow the `job()` fixture pattern in `usage-summary.test.sh`: a job folder whose `job.json` is built with `jq -n`. Every test runs `assert_exit <code> <msg> -- "$FACTORY_SRC/bin/retro-due" "$J"`:
  - `test_clean_merged_not_due`: `{stage:"merged",round:1,reworks:0,respecs:0,tasks:[{runs:1}]}` → 1
  - `test_rounds_due`: `round:8` → 0
  - `test_rework_respec_due`: `reworks:1` → 0, and separately `respecs:1` → 0
  - `test_task_rerun_due`: a task with `runs:2` → 0 (job 002's shape)
  - `test_old_job_files_due`: a clean `job.json` plus an empty `rework-1.md` → 0, and the same with `decision-round1.md` → 0
  - `test_escalate_decision_due`: a clean `job.json`, with `decision.md` starting `ESCALATE` → 0
  - `test_not_end_state`: `stage:"needs-human"`, `round:8` → 1
  - `test_dropped_due`: `stage:"dropped"`, `reworks:1` → 0
  - `test_already_has_retro`: `round:8` plus `retro.md` → 1
  - `test_usage`: no argument → 2; a folder with no `job.json` → 2

- [ ] **Step 2:** Run `bash factory/test/retro-due.test.sh`. Expect it to FAIL (the script doesn't exist).

- [ ] **Step 3:** Implement `factory/bin/retro-due`. Read the counts with one `jq -e` over `job.json`, defaulting missing fields with `// 0`. Do the file checks with `compgen -G`.

- [ ] **Step 4:** Run `bash factory/test/retro-due.test.sh`. Expect `10 passed` or more and `0 failed`.

- [ ] **Step 5:** Commit: `git add factory/bin/retro-due factory/test/retro-due.test.sh && git commit -q -m "Add retro-due: which finished jobs need a retro"`.

### Task 2: Trend line in `usage-summary`

**Files:**
- Modify: `factory/bin/usage-summary`. Update the header comment. The early `quota: no data` exit and the input list must now take in every `factory/jobs/*/job.json`, not only ones that have a sibling `usage.jsonl`.
- Test: `factory/test/usage-summary.test.sh`

**Interfaces:**
- Produces one extra line, printed after the per-job lines and before the `quota:` line:
  `trend (last <n> merged): first-pass <x>/<n>, median rounds <r>, median reworks+respecs <w>, median tokens <t>M`
  - `<n>` is up to 10 jobs with `stage == "merged"`, newest first by `.updated`, with `.id` as a fallback.
  - A first-pass job has `round <= 1`, `reworks` and `respecs` of 0, `human_decision` null, and every `tasks[].runs <= 1`.
  - `<r>` and `<w>` use the existing `r1` formatting.
  - `<t>` is the median over those jobs that have usage, of `input + output` in millions, formatted with `r1`. It prints `n/a` when none of them have usage.
  - With no merged jobs, the line is left out.

- [ ] **Step 1: Write the failing tests:**
  - `test_trend_line`: three merged jobs:
    - one with `round:1`, all zeros, and usage of 1,000,000 in;
    - one with `round:3`, `reworks:1`, and usage of 3,000,000 in;
    - one with `round:8`, `reworks:2`, `respecs:1`, and no usage file.

    Assert `trend (last 3 merged): first-pass 1/3, median rounds 3.0, median reworks+respecs 1.0, median tokens 2.0M`.
  - `test_trend_no_usage`: one merged job with no `usage.jsonl` gives the output `trend (last 1 merged): first-pass 1/1, median rounds 1.0, median reworks+respecs 0.0, median tokens n/a`, then `quota: no data`, then `claude: tokens only`.
  - `test_trend_caps_at_ten`: 12 merged jobs with increasing `updated` gives `last 10 merged`.
  - Extend `job()`, or add `jobj <id> <job-json> [usage lines]`, so fixtures can set `round`, `reworks`, `updated` and so on.
  - Update `test_finished_jobs_no_line` and `test_flag_needs_three_finished`: their merged fixtures now produce a trend line. Change the exact-match assertions to expect it, with dropped jobs left out of the trend.

- [ ] **Step 2:** Run `bash factory/test/usage-summary.test.sh`. Expect the new tests to FAIL.

- [ ] **Step 3:** Implement the change. Collect every job folder's `job.json` (with or without usage), compute the trend in the same jq program from `$jobs` and the `job.json` objects, and emit it between the per-job lines and the quota expression.

- [ ] **Step 4:** Run `bash factory/test/usage-summary.test.sh`. Expect everything to PASS.

- [ ] **Step 5:** Commit: `git commit -q -am "usage-summary: trend line over the last 10 merged jobs"`, after `git add` of the test.

### Task 3: `retro-prep`

**Files:**
- Create: `factory/bin/retro-prep`
- Modify: `factory/settings.example.json`. Add `"factory_source": ""`; the empty value means unset, and `settings` already prints it as an empty string.
- Test: `factory/test/retro-prep.test.sh`

**Interfaces:**
- Consumes:
  - `factory/bin/settings land|base|factory_source`;
  - `factory/bin/job-set`;
  - `gh pr list --label factory-retro --state all --limit 200 --json number,title,state,url,headRefName,body`.
- Produces: `factory/bin/retro-prep <job folder>`. Run it from anywhere; `<repo>` is two levels above the script, `<name>` is its basename and `<id>` is `job.json` `.id`.
  - **Exit codes:** 0 ok, 1 environment failure (git or gh failed, or `factory_source` isn't a git repo), 2 usage error.
  - **stdout:** two lines:
    - `repo <worktree path>`
    - `factory <worktree path> source` or `factory <worktree path> installed`
  - **Repo worktree:** at `<repo>/../<name>-factory/retro-<id>`. Any existing worktree there is removed with `--force` first.
    - Branch choice with `land: "pr"`, using `gh` run in `<repo>`, looking at PRs whose `headRefName` is `factory/retro-<id>` or starts with `factory/retro-<id>-`:
      - an `OPEN` PR: fetch its branch, put the worktree on it (`-B <branch> origin/<branch>`), and set `retro_pr` to that PR's url;
      - otherwise: the first of `factory/retro-<id>`, `-2`, `-3`, … that has no local branch, no `origin` branch and no PR, created from `<base>`, with `retro_pr` set to null.
    - Branch choice with `land: "local"` (no `gh` calls):
      - reuse local `factory/retro-<id>` while it isn't an ancestor of `main`;
      - otherwise take the next unused `-<k>` from `main`.
    - The bodies of this job's `CLOSED` (not merged) PRs, from both repos, go into `<job>/retro-rejected.md`, each under `## <url>`. When there are none, the file is removed.
  - **Factory worktree when `factory_source` is set:**
    - `git -C <src> fetch -q origin`, then the same branch rules against `<src>` and `origin/main`, using the `retro/<name>-<id>` prefix. The worktree goes at `<src>/../<srcname>-factory/retro-<name>-<id>`.
    - `retro_factory_pr` is set the same way as `retro_pr`.
    - Every `factory-retro` PR in `<src>` (all states, the fields above) goes to `<job>/retro-factory-prs.json`.
    - Run `diff -rq` between `<repo>` and the factory worktree on `.claude/skills/factory`, `.claude/agents/factory-agent.md`, `factory/agents`, `factory/bin` and `factory/dashboard.html`. Any output goes to `<job>/retro-stale.txt`; no output removes the file.
  - **Factory worktree when `factory_source` is unset:**
    - Copy the installed paths into `<job>/.retro-factory/`: the five paths above plus `factory/models.json` and `factory/autopilot-policy.md`.
    - Then `git init -q`, `git add -A` and `git commit -q -m installed` there.
    - The line says `installed`, and `retro_factory_pr` is set to null.
  - **`job.json`, in one `job-set` call:** `retro_worktree`, `retro_factory_worktree`, `retro_factory_kind` (`source` or `installed`), `retro_pr` and `retro_factory_pr`.

- [ ] **Step 1: Write the failing tests.** Use `mkrepo` for the target, and a second `mkrepo` as the source (add `.claude/skills/factory/SKILL.md` to it and push). Stub `gh` with a `case` on `"$*"`, as in `land.test.sh`. Make `gh pr list` return the JSON in `$PRS` and `$SRC_PRS` (pick one by `$PWD`).
  - `test_new_branch_from_base`: no PRs gives stdout `repo …/retro-001-a` and `factory …/.retro-factory installed`. The branch is `factory/retro-001-a` at `origin/main`, and `retro_pr` is null.
  - `test_open_pr_reused`: push `factory/retro-001-a` with an extra commit; the PR is `OPEN`. The worktree HEAD is that commit, and `retro_pr` is the url.
  - `test_merged_pr_next_branch`: the PR on `factory/retro-001-a` is `MERGED` and the branch exists on origin. The new branch is `factory/retro-001-a-2`.
  - `test_closed_pr_rejected`: the PR is `CLOSED` with the body `drop the CDK lesson`. `retro-rejected.md` contains `## <url>` and `drop the CDK lesson`, and the new branch is `-2`.
  - `test_local_mode`: `{"land":"local"}` makes no `gh` calls (`gh.calls` doesn't exist) and reuses an unmerged local `factory/retro-001-a`.
  - `test_factory_source`: with `factory_source` set to the source repo, the branch is `retro/work-001-a` from the source's `origin/main`. `retro-factory-prs.json` is valid JSON, and stdout ends `source`.
  - `test_stale_install`: change `factory/bin/job-set` in the target. `retro-stale.txt` names `job-set`.
  - `test_stale_worktree_replaced`: run `retro-prep` twice. The second run exits 0.
  - `test_bad_source`: `factory_source` is a non-git dir → exit 1.

- [ ] **Step 2:** Run `bash factory/test/retro-prep.test.sh`. Expect it to FAIL.

- [ ] **Step 3:** Implement `factory/bin/retro-prep`. One helper, `pick_branch <git-dir> <prefix> <base-ref> <prs-json>`, prints `<branch> <open-pr-url|->` and is used for both repos. A second helper, `add_worktree <git-dir> <path> <branch> <start-ref>`, removes any stale worktree first.

- [ ] **Step 4:** Run `bash factory/test/retro-prep.test.sh` and `bash factory/test/settings.test.sh`. Expect both to PASS.

- [ ] **Step 5:** Commit the script, the test and `settings.example.json`, with the message `Add retro-prep: worktrees and context for a retro`.

### Task 4: `retro-publish`

**Files:**
- Create: `factory/bin/retro-publish`
- Test: `factory/test/retro-publish.test.sh`

**Interfaces:**
- Consumes the `job.json` fields that Task 3 writes, plus these files the role writes in the job folder:
  - `retro.md`;
  - `retro-pr-repo.md` and `retro-pr-factory.md` (PR bodies);
  - `retro-comment-<number>.md` (comments for existing ai-factory PRs).
- Produces: `factory/bin/retro-publish <job folder>`.
  - **Exit codes:** 0 ok, 1 failure (a bad `retro.md` first line, a missing PR body when one is needed, or a git or gh failure), 2 usage error.
  - **Count:** `<n>` comes from `retro.md`'s first line, with 0 for `nothing to change`.
  - **Repo worktree, when `git status --porcelain` is non-empty:**
    1. `git add -A` and `git commit -q -m "Retro <id>: <n> lessons"`.
    2. With `land: "pr"`: `git push -q -u origin <branch>`.
    3. If `retro_pr` is null: `gh label create factory-retro --force`, then `gh pr create --base main --head <branch> --label factory-retro --title "Retro <id>: <n> lessons" --body-file <job>/retro-pr-repo.md`, and set `retro_pr` to the url it prints.
    4. With `land: "local"`: commit only.
  - **Factory worktree, kind `source`:** the same steps, in `<src>`, with `--body-file retro-pr-factory.md`. It always opens a PR, whatever the `land` setting. Then `gh pr comment <number> --body-file <f>` for each `retro-comment-<number>.md`, and rename each posted file to `retro-comment-<number>.posted.md`.
  - **Factory worktree, kind `installed`, with changes:** write `<job>/retro-factory.patch`. The first line is `# Against the factory installed in <repo>, not ai-factory's main.`, followed by `git -C <job>/.retro-factory diff`. Then remove `.retro-factory/`.
  - **Cleanup:** `git worktree remove --force` both worktrees. Branches are kept. Set `retro_worktree` and `retro_factory_worktree` to null.
  - **stdout:** one line, `retro <id>: <n> fixes, <repo part>, <factory part>`:
    - the repo part is the PR url, `branch <name>` (local mode), or `no repo changes`;
    - the factory part is the PR url, `patch <path>`, or `no factory changes`.

- [ ] **Step 1: Write the failing tests.** Run `retro-prep`, then write the role's outputs by hand: edit `AGENTS.md` in the repo worktree, and so on.
  - `test_opens_repo_pr`: `gh.calls` has `pr create` with `--label factory-retro` and `--title Retro\ 001-a:\ 2\ lessons`. `job.json` `retro_pr` is the stub url, and the line contains the url.
  - `test_label_created_before_pr`: in `gh.calls`, the `label create factory-retro --force` line comes before `pr create`.
  - `test_open_pr_pushes_only`: with `retro_pr` already set, there is a push and no `pr create`.
  - `test_nothing_to_change`: `RETRO: nothing to change` and no edits give no commit on the branch, no `gh` calls, and the line `retro 001-a: 0 fixes, no repo changes, no factory changes`.
  - `test_local_mode_branch_only`: no `gh` calls, the line has `branch factory/retro-001-a`, and the branch has the commit.
  - `test_installed_patch`: edit `factory/agents/x.md` in `.retro-factory`. `retro-factory.patch` starts with `# Against the factory installed in`, and `.retro-factory` is gone.
  - `test_factory_pr_and_comment`: in source mode, opens a PR in the source and posts `pr comment 12`.
  - `test_comment_posted_once`: a second publish posts no comment.
  - `test_bad_first_line`: `retro.md` starting with `hello` → exit 1.
  - `test_worktrees_removed`: both worktree paths are gone, and the `job.json` fields are null.

- [ ] **Step 2:** Run `bash factory/test/retro-publish.test.sh`. Expect it to FAIL.

- [ ] **Step 3:** Implement `factory/bin/retro-publish`. Use one helper, `publish_one <git-dir> <worktree> <branch> <pr-url|null> <title> <body-file> <push:yes|no>`, for both PR paths. It prints the PR url (existing or new), or nothing when there are no changes.

- [ ] **Step 4:** Run `bash factory/test/retro-publish.test.sh` and `factory/test/run`. Expect all of it to PASS.

- [ ] **Step 5:** Commit: `Add retro-publish: commit, PR and clean up a retro`.

### Task 5: The retro role

**Files:**
- Create: `factory/agents/retro.md`
- Modify: `factory/models.json`. Add `"retro": { "provider": "anthropic", "model": "sonnet" }`, aligned like the other entries.
- Test: `factory/test/prose.test.sh`. Add `test_retro_role`.

**Interfaces:**
- Consumes:
  - the prompt `Role: factory/agents/retro.md. <paths> Retro. Retro worktree: <path>. Factory worktree: <path> (<source|installed>).`;
  - from the job folder: `retro-rejected.md`, `retro-factory-prs.json` and `retro-stale.txt`.
- Produces:
  - `retro.md`, in the spec's format;
  - `retro-pr-repo.md`, when it edited the repo worktree;
  - `retro-pr-factory.md`, when it edited a `source` factory worktree;
  - `retro-comment-<number>.md`, when a fix repeats an open ai-factory PR;
  - edits in the two worktrees.

  It never commits, pushes or runs `gh`, and it never writes outside those paths.

- [ ] **Step 1: Write the failing test.** `test_retro_role` asserts that `factory/agents/retro.md` contains each of:
  - the first-line forms: `RETRO: <n> fixes` and `RETRO: nothing to change`;
  - the five section headings: `## Cost`, `## What each extra attempt was for`, `## Fixes`, `## Repeats`, `## Drafted beads`;
  - all ten causes, joined as one backticked list;
  - `## Lessons from factory jobs`, `retro-rejected.md`, `retro-factory-prs.json`, `retro-stale.txt` and `retro-comment-`;
  - `never commit`.

  It also asserts `jq -r .retro.model factory/models.json` is `sonnet`.

- [ ] **Step 2:** Run `bash factory/test/prose.test.sh`. Expect `test_retro_role` to FAIL.

- [ ] **Step 3: Write `factory/agents/retro.md`.** Match the shape of `spec-writer.md`: what the role is, `## Where you work`, `## Read first`, `## Write`, `## Finish`. It must say:
  - **Reading budget:** what to read in full, and to read only the first line, `## Findings` and `## Notes` of each `round-<N>/review-*.md`. It opens a full review, build report or `.runs/` log only to explain an extra attempt.
  - **Attempts:** one line per extra round, rework, respec or rerun, with a cause from the fixed list and a cited file and round.
  - **Quality bar:** a fix names its file, is actionable on the next job, and cites the attempt it saves. Facts that only matter to this job stay out of `## Fixes`.
  - **Repo edits:** the allowed files, with lessons merged or replaced in place to stay at 30 lines or fewer.
  - **Factory edits:** the allowed files. In `installed` mode, edit `.retro-factory` the same way; it becomes a patch.
  - **Repeats:** check earlier `factory/jobs/*/retro.md`, the existing lessons in `AGENTS.md`, and `retro-factory-prs.json`. A repeat of an open ai-factory PR becomes a `retro-comment-<number>.md` with the new evidence, not a new edit. A repeat that is already in place means the fix didn't work: strengthen it or change the mechanism.
  - **Rejected fixes:** never re-propose anything in `retro-rejected.md`.
  - **Stale install:** when `retro-stale.txt` exists, say so in `## Cost`'s last line and in the repo PR body.
  - **Drafted beads:** one runnable `bd create "<title>" --type=task -d "<why, with evidence path>"` line each. Never run `bd` writes.
  - **PR bodies:** the `## Fixes` entries for that kind, plus `## Drafted beads` in the repo body.
  - **Finish:** one line per file written, as in `factory-agent.md`.

- [ ] **Step 4:** Run `bash factory/test/prose.test.sh`. Expect everything to PASS.

- [ ] **Step 5:** Commit: `Add the retro role`.

### Task 6: Wire the retro into `SKILL.md`, README and INSTALL

**Files:**
- Modify: `.claude/skills/factory/SKILL.md`:
  - the description (line 3): add `/factory retro <job-id>`;
  - the step table: a `retro` row writing `retro.md` and the PR bodies;
  - **Files**: the retro files, `.retro-factory/`, and the retro worktree paths;
  - **job.json**: the five `retro*` fields;
  - **Merge** exit 0: add `then **Retro**` after `usage-record session`;
  - **/factory resume** DROP: the same;
  - a new `### Retro` subsection after `### Merge`;
  - a new `## /factory retro <job-id>` section after `## /factory review`;
  - **Reporting**: the retro line.
- Modify: `README.md`. Add a short section on retros, the `factory_source` setting and the trend line.
- Modify: `INSTALL.md`. In the settings step, add `factory_source` as optional, with a one-line meaning.
- Test: `factory/test/prose.test.sh`. Add `test_retro_wiring`.

**Interfaces:**
- Consumes the Task 1, 3, 4 and 5 interfaces, exactly as named there.
- The `### Retro` subsection is the procedure:
  1. Unless the job came from `/factory retro`, run `factory/bin/retro-due <job folder>`. On exit 1, stop silently.
  2. Run `factory/bin/retro-prep <job folder>` in the foreground, and read its two lines.
  3. Run the `retro` role (anthropic) with the task `Retro. Retro worktree: <path>. Factory worktree: <path> (<kind>).`, then `usage-record claude <job folder> retro`.
  4. Check that `retro.md`'s first line matches.
  5. Run `factory/bin/retro-publish <job folder>`, and print its line.
  6. Any non-zero exit, or a bad first line: tell the user in one line, quoting stderr, and stop. **A retro never changes `stage` or `situation`.** A headless drain carries on to its next job.

- [ ] **Step 1: Write the failing test.** `test_retro_wiring` asserts:
  - `SKILL.md` line 3 contains `/factory retro`;
  - `section "$f" '/factory retro <job-id>'` exists and says to skip `retro-due`;
  - `tr`-flattened `SKILL.md` contains each of: `factory/bin/retro-due <job folder>`, `factory/bin/retro-prep <job folder>`, `factory/bin/retro-publish <job folder>`, `usage-record claude <job folder> retro`, `A retro never changes \`stage\` or \`situation\`` and `retro_pr`;
  - the Merge section's exit-0 text and the DROP text each contain `**Retro**`;
  - `README.md` contains `factory_source`, and `INSTALL.md` contains `factory_source`.

- [ ] **Step 2:** Run `bash factory/test/prose.test.sh`. Expect `test_retro_wiring` to FAIL.

- [ ] **Step 3:** Make the edits listed under **Files**, keeping to the surrounding prose style: short imperative lines, with commands in backticks.

- [ ] **Step 4:** Run `factory/test/run`. Expect `all test files passed`.

- [ ] **Step 5:** Commit: `Run a retro after expensive jobs, and add /factory retro`.

### Task 7: Dashboard

**Files:**
- Modify: `factory/dashboard.html`:
  - `fileRank`: put `retro.md` right after `decision.md` in `order`;
  - the drawer header (around `d-title`): when `job.retro_pr` or `job.retro_factory_pr` is set, show them as links (`target="_blank" rel="noopener"`), labelled `retro PR` and `factory retro PR`;
  - the card: a small `retro` marker when either is set. No links inside the card `<button>`.
- Test: `factory/test/prose.test.sh`. Add `test_dashboard_retro`, which greps `dashboard.html` for `retro_pr`, `retro_factory_pr` and `'retro.md'`.

- [ ] **Step 1:** Write `test_dashboard_retro`. Run it and expect it to FAIL.
- [ ] **Step 2:** Make the edits. Escape values with the existing `esc()`.
- [ ] **Step 3:** Run `factory/test/run`, and expect PASS. Then serve the repo as the README says, and open the dashboard against a fixture job folder that has `retro.md` and `retro_pr`. Confirm the link and the file order by eye.
- [ ] **Step 4:** Commit: `Dashboard: link a job's retro`.

### Task 8: Acceptance run on copies of jobs 001 and 002

This runs the real `retro` role on `sonnet`, so it uses Claude quota. It never touches garmin-ai-coach itself.

**Files:** nothing committed. Everything lives in the session scratchpad.

- [ ] **Step 1: Build the test repo.** Create `<scratchpad>/retro-acceptance` with `git init -b main`. Install the factory from this branch, following `INSTALL.md` step 3. Copy `~/Development/garmin-ai-coach/AGENTS.md` into it. Then `cp -R ~/Development/garmin-ai-coach/factory/jobs/{001,002}-*` into `factory/jobs/`, write `factory/settings.json` as `{"land":"local"}`, and commit.
- [ ] **Step 2:** Run `factory/bin/retro-due` on both jobs. Expect exit 0 for each.
- [ ] **Step 3:** In that repo, run `/factory retro 001-event-bus-tenant-boundary`. Expect:
  - `retro.md` explains all 8 rounds;
  - `## Fixes` covers spec causes 1–6:
    - CDK logical-ID hashing and SQS at-least-once delivery as `repo` fixes;
    - findings batching, PASS-with-notes, UI/UX on non-UI diffs, and the sandbox Beads/git locks as `factory` fixes;
  - drafted beads for any non-doc work;
  - branch `factory/retro-001-event-bus-tenant-boundary` changes only `AGENTS.md`;
  - `retro-factory.patch` exists;
  - the lessons section is about 30 lines or fewer.
- [ ] **Step 4:** Run it again on the same job. Because `land` is local and the branch isn't merged, expect the same branch to get a new commit on top, `retro.md` to be replaced, and no new branch.
- [ ] **Step 5:** Run `factory/bin/usage-summary`. Expect a `trend (last 2 merged): first-pass 0/2, …` line.
- [ ] **Step 6:** Report to the user:
  - the `retro.md` cost and fixes sections;
  - the `AGENTS.md` diff and the patch;
  - any acceptance item that missed, quoted.

  Don't tune the role prompt to fit job 001 specifically: a miss means the role prompt needs a general fix, and that fix goes back through Task 5.
