# Factory: Parallel Jobs, Spend Visibility and Human Review — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port garmin-ai-coach's factory changes into ai-factory, fix findings 1–3, add per-run usage and quota visibility, add `/factory review` with resubmission to the drain, and run several autopilot jobs at once.

**Architecture:** Behaviour lives in small bash scripts under `factory/bin/` (each prints one line, writes detail to files) and in prose in `.claude/skills/factory/SKILL.md` and `factory/agents/*.md`. Scripts get plain-bash tests in `factory/test/` that stub `gh`, `bd`, `codex` and `claude` on `PATH` and use real throwaway git repos. Prose changes are verified by `grep` checks in the same test suite.

**Tech Stack:** bash, jq, git, gh, bd (Beads), codex CLI, Claude Code; vanilla JS in `factory/dashboard.html`.

**Spec:** `docs/superpowers/specs/2026-10-19-factory-parallel-and-spend-design.md`

## Global Constraints

- Scripts are bash + `jq` + `git` + `gh`, `set -uo pipefail`, header comment in the style of `factory/bin/job-set` (usage line, what it prints, exit codes).
- The orchestrator's context stays small: every script prints at most one line on success; detail goes to files.
- No `flock` (absent on macOS): locks are `mkdir <dir>` / `rmdir <dir>`.
- `--jobs` defaults to 1; `land` defaults to `pr`; `priority_labels` defaults to `[]`. With no `factory/settings.json` behaviour equals today's except PR landing and the findings fixes.
- Spend never drives a decision: no script stops, pauses or switches anything on usage.
- Missing usage fields are `null`, never guessed. A usage-recording failure never fails the run it records.
- Reference implementation for ports: `~/Development/garmin-ai-coach` at `f216500a` (`factory/bin/pr-land`, `factory/bin/next-bead`, SKILL.md and role-file diffs in `94450b8b`, `f216500a`).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on branch `design/parallel-and-spend` (or a branch from it); never commit to `main`.

## Review Focus

1. A Codex run that dies mid-stream (no `turn.completed`, truncated last line, like `174931-builder`) — `usage-record` writes a line with null tokens and `ended` = the last event type, and `run-codex` still exits with codex's code. Test in Task 7.
2. A repo with no required checks, or no checks at all — `pr-land` must not wait ~10 minutes and fail; it watches all checks, or merges at once. Test in Task 3.
3. Two workers racing for the same bead or the same resubmitted job — exactly one wins; the other picks again. Tests in Tasks 13 and 15.
4. `origin/main` moving while `pr-land` waits for CI — it re-checks the base right before `gh pr merge` and exits 6 instead of merging. Test in Task 3.
5. The same subagent transcript recorded twice (orchestrator calls `usage-record claude` after every subagent; streamed assistant messages repeat) — one usage line per transcript, tokens de-duplicated by message id. Test in Task 8.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `factory/settings.json` (new, optional in target repos; ship `factory/settings.example.json`) | `land`, `priority_labels`, `jobs` |
| `factory/bin/settings` (new) | read one setting with default; derives `base` |
| `factory/bin/next-bead` (port) | next queued bead in priority-label order |
| `factory/bin/land` (new) | dispatch to `pr-land` / `local-land` by `land` setting |
| `factory/bin/pr-land` (port + changes) | land via PR, exit codes 0/3/4/5/6 |
| `factory/bin/local-land` (new) | land via local merge, exit codes 0/4/6/7 |
| `factory/bin/beads-snapshot` (new) | write `<job>/beads.md` for sandboxed roles |
| `factory/bin/usage-record` (new) | append one usage line to `<job>/usage.jsonl` |
| `factory/bin/usage-summary` (new) | one-line-per-job spend + quota for `/factory status` |
| `factory/bin/bd-stress` (new) | concurrent Beads write stress test |
| `factory/bin/run-codex`, `run-adversarial`, `autopilot` (modify) | MCP off, base ref, usage, workers |
| `factory/agents/briefer.md` (new) | human brief + decision writer |
| `factory/agents/*.md` (modify) | `<base>`, `beads.md`, `human-*.md` |
| `factory/dashboard.html` (modify) | usage + quota panels, resubmitted/dropped |
| `.claude/skills/factory/SKILL.md` (modify) | landing, base, review, resubmit, resume, status |
| `factory/AGENTS.template.md`, `INSTALL.md`, `README.md` (modify) | rules and install steps |
| `factory/test/lib.sh`, `factory/test/run`, `factory/test/*.test.sh`, `factory/test/fixtures/` (new) | tests |

---

## Phase 1 — Port and findings fixes

### Task 1: Test harness and `settings`

**Files:**
- Create: `factory/test/lib.sh`, `factory/test/run`, `factory/test/settings.test.sh`, `factory/bin/settings`, `factory/settings.example.json`

**Interfaces:**
- Produces (lib.sh): `assert_eq <expected> <actual> <msg>`, `assert_contains <haystack> <needle> <msg>`, `assert_exit <code> <msg> -- <cmd...>`, `mkrepo` (prints path of a temp repo with an initial commit on `main`, a bare `origin`, `origin/main` fetched, and a copy of this repo's `factory/` in it), `stub <name> <body>` (writes an executable `$STUBS/<name>` running `<body>`; `$STUBS` is first on `PATH`; every stub call is appended to `$STUBS/<name>.calls`), `finish` (prints `N passed, M failed`, exits non-zero on failure).
- Produces: `factory/bin/settings <key> [<default>]` → prints the value (arrays space-joined). Reads `<repo>/factory/settings.json` where `<repo>` is two levels above the script. Key `base` is derived: `origin/main` when `land` is `pr`, `main` when `local`. `FACTORY_SETTINGS` env overrides the file path.
- `factory/test/run` runs every `factory/test/*.test.sh` and fails if any fails.

- [ ] **Step 1: Write `settings.test.sh`**
  - `test_defaults_without_file`: `settings land` → `pr`; `settings jobs 1` → `1`; `settings priority_labels` → empty; `settings base` → `origin/main`.
  - `test_local_mode_base`: settings file `{"land":"local"}` → `settings base` = `main`.
  - `test_array_joined`: `{"priority_labels":["lane:a","lane:b"]}` → `lane:a lane:b`.
  - `test_malformed_file`: file `{` → exit non-zero, stderr contains `settings:`.
- [ ] **Step 2: Run `factory/test/run`** — Expected: FAIL (`settings` missing).
- [ ] **Step 3: Implement `factory/bin/settings` and `lib.sh`/`run`.** `settings.example.json` = `{"land":"pr","priority_labels":[],"jobs":1}`.
- [ ] **Step 4: Run `factory/test/run`** — Expected: all pass; `shellcheck factory/bin/settings factory/test/*.sh` clean.
- [ ] **Step 5: Commit** — `git commit -m "Add factory settings and a test harness"`.

### Task 2: `next-bead`

**Files:**
- Create: `factory/bin/next-bead` (port), `factory/test/next-bead.test.sh`
- Modify: `factory/bin/autopilot:57` (use `next-bead`), `.claude/skills/factory/SKILL.md` (**/factory next**, **/factory status**)

**Interfaces:**
- Consumes: `settings priority_labels`.
- Produces: `factory/bin/next-bead` → prints one bead id or nothing; never claims. `FACTORY_PRIORITY_LABELS` overrides the setting.

- [ ] **Step 1: Write tests** with a `bd` stub returning a fixed `bd ready --json` array of 3 beads (ids `a` P2 old, `b` P1 new, `c` P3 labelled `lane:x`):
  - `test_plain_priority`: no labels → `b`.
  - `test_label_first`: settings `priority_labels: ["lane:x"]` → `c`.
  - `test_env_override`: `FACTORY_PRIORITY_LABELS=nope` with the setting present → `b`.
  - `test_empty_queue`: stub returns `[]` → prints nothing, exit 0.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Port** garmin's `next-bead`; replace the hard-coded label default with `$(factory/bin/settings priority_labels)`; header comment drops `docs/alpha-path.md`.
- [ ] **Step 4: Update SKILL.md** `/factory next` and `/factory status` to garmin's text, with "beads carrying a priority label from `factory/settings.json`" instead of the lane list. `/factory next` claims with `bd update <bead> --claim`, picking again on failure.
- [ ] **Step 5: Run** — Expected: pass; `grep -c 'alpha-path\|lane:' .claude/skills/factory/SKILL.md factory/bin/*` → 0.
- [ ] **Step 6: Commit** — `"Pick queued beads by priority label from settings"`.

### Task 3: Landing — `land`, `pr-land`, `local-land`, moved-base rule

**Files:**
- Create: `factory/bin/land`, `factory/bin/pr-land` (port + changes), `factory/bin/local-land`, `factory/test/land.test.sh`
- Modify: `.claude/skills/factory/SKILL.md` (**Merge**, **Review round N** step 1, **job.json** fields, **Autopilot decision** MERGE gate, **/factory resume** step 3), `factory/autopilot-policy.md`, `.gitignore`

**Interfaces:**
- Consumes: `settings land`, `settings base`; `job.json` fields `id`, `bead`, `feature`, `worktree`, `round`, `reviewed_base`.
- Produces:
  - `factory/bin/land <job-folder>` → execs `pr-land` or `local-land`. Exit codes, shared: **0** merged; **3** required checks failed (log `<job>/.runs/checks.log`); **4** conflicts with base; **5** GitHub refused the merge; **6** base moved since `reviewed_base`, branch updated with a merge commit, re-review needed; **7** main checkout busy (local only); other = environment failure. `pr-land` prints the PR url as its first stdout line.
  - New `job.json` fields: `reviewed_base` (sha, set by the orchestrator at the start of each review round: `git rev-parse <base>` after fetching in pr mode), `pr` (url).
- Moved-base algorithm (both scripts), run after fetch and again immediately before the merge call:
  ```
  if git merge-base --is-ancestor "$(git rev-parse <base>)" "$reviewed_base"; then base unchanged
  elif merge-tree clean: git -C <worktree> merge --no-ff --no-edit <base>; (pr: push); exit 6
  else exit 4
  ```

- [ ] **Step 1: Write tests** (real git via `mkrepo`, `gh` stub scripted per test):
  - `test_pr_merges_with_required_checks`: gh `pr list` → empty, `pr create` → url, `pr checks --required` → ok → exit 0; stdout line 1 is the url; `gh.calls` contains `pr merge` with `--squash`.
  - `test_pr_no_required_checks_watches_all`: `pr checks --required` prints `no required checks reported` (exit 1); `pr checks` (no `--required`) → ok → exit 0 within the test's 5s timeout (set `PR_LAND_REGISTER_WAIT=0`).
  - `test_pr_no_checks_at_all_merges`: both checks calls say `no checks reported` → exit 0, merged.
  - `test_pr_reuses_open_pr`: `pr list` returns a url → no `pr create` in calls.
  - `test_pr_checks_fail`: `--watch` exits 1 → exit 3, `.runs/checks.log` exists.
  - `test_conflict`: commit conflicting change to origin main → exit 4, no push.
  - `test_base_moved_clean`: `reviewed_base` = old sha, add a non-conflicting commit to origin main → exit 6; job branch has a merge commit whose second parent is the new origin/main; `gh.calls` has no `pr merge`.
  - `test_base_moves_during_ci_wait`: gh `pr checks --watch` stub pushes a new commit to origin main before returning ok → exit 6, no `pr merge`.
  - `test_local_merges`: `land:"local"`, clean main checkout on `main` → exit 0, `main` contains the job branch, no `git push` (origin unchanged).
  - `test_local_busy_checkout`: dirty file outside `factory/` → exit 7.
  - `test_local_lock_serialises`: two `local-land` runs on two jobs started together → both exit 0 (or one 6), never a failed merge; lock dir `factory/.land-lock` removed afterwards.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Port `pr-land`** from garmin; changes: base from `settings base`; register wait loop length from `PR_LAND_REGISTER_WAIT` (default 40 × 15s); fall back from `--required` to all checks, and to merging when there are none; moved-base check after fetch and right before `gh pr merge`; drop the "drafts skip CI" comment.
- [ ] **Step 4: Implement `local-land`**: precondition `git status --porcelain -- . ':!factory/'` empty and branch `main` else 7; lock `mkdir factory/.land-lock` (retry every 2s up to 10 min); moved-base check with `reviewed_base`; `git merge -q --no-ff factory/<id> -m "Merge factory/<id>"`; on failure `git merge --abort` and exit 4; never pushes. `land` dispatches.
- [ ] **Step 5: Update SKILL.md**: **Merge** = garmin's text, running `factory/bin/land`, with exit 6 → set `reviewed_base` and go to **Review round N+1** (counts against `MAX_ROUNDS`), exit 7 → `merge-blocked`. **Review round N** step 1 sets `reviewed_base`. **job.json** documents `pr`, `reviewed_base`. **/factory resume** step 3 = garmin's PR check, plus local mode: `git merge-base --is-ancestor factory/<id> main`. `autopilot-policy.md`: "only the orchestrator's **Merge** step pushes, and only the job branch". `.gitignore` adds `/factory/.land-lock`.
- [ ] **Step 6: Run** — Expected: all pass, shellcheck clean.
- [ ] **Step 7: Commit** — `"Land jobs through a PR or a local merge, re-reviewing when the base moved"`.

### Task 4: Base ref everywhere

**Files:**
- Modify: `factory/agents/{planner,builder,reviewer-code,reviewer-security,reviewer-ux,reviewer-ui,approver,autopilot,spec-writer}.md`, `factory/bin/run-adversarial` (`--base main`), `.claude/skills/factory/SKILL.md` (**Prompts**, **/factory <feature>** step 3, **Autopilot decision** MERGE gate), `factory/AGENTS.template.md`, `INSTALL.md` (step 2 "default branch is main" and the settings step), `README.md`
- Test: `factory/test/prose.test.sh`

**Interfaces:**
- Consumes: `settings base`.
- Produces: standard prompt line `<paths>` gains ` Base: <base>.`; role files say "the base ref from your prompt (`<base>`)". `run-adversarial` passes `--base "$(settings base)"`.

- [ ] **Step 1: Write `prose.test.sh`**: `test_no_literal_main_diffs` — `grep -nE '(main\.\.|main\.\.\.|merge-tree --write-tree (origin/)?main|--base main)' factory/agents/*.md factory/bin/* .claude/skills/factory/SKILL.md` prints nothing; `test_prompt_has_base` — SKILL.md **Prompts** contains `Base: <base>.`; `test_agents_rule` — `AGENTS.template.md` contains `never commit or push to main directly` and the local-mode exception sentence.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Edit** role files and SKILL.md: every `main..<branch>` / `main...<branch>` / merge-tree target becomes `<base>`; worktree creation is `git fetch -q origin main` (pr mode only) then `git worktree add -q -b factory/<job-id> <worktree> <base>`. AGENTS.template.md rule: "Never commit or push to main directly. In local land mode the factory's Merge step is the only thing that commits to main." INSTALL.md adds a step to write `factory/settings.json` (ask: GitHub remote → `pr`, else `local`; priority labels).
- [ ] **Step 4: Run** — Expected: pass.
- [ ] **Step 5: Commit** — `"Pass the base ref to every role instead of naming main"`.

### Task 5: Beads state for sandboxed roles (findings fix 1)

**Files:**
- Create: `factory/bin/beads-snapshot`, `factory/test/beads-snapshot.test.sh`
- Modify: `factory/agents/{approver,autopilot,reviewer-security,builder}.md` (every Codex role that reads Beads), `.claude/skills/factory/SKILL.md` (**Running a role**: run `beads-snapshot` before every `run-codex`)

**Interfaces:**
- Produces: `factory/bin/beads-snapshot <job-folder>` → writes `<job-folder>/beads.md` (sections `## Bead` = `bd --readonly show <bead>`, `## Children` = `bd --readonly children <bead>` with status) and prints `beads.md: <n> children, <m> open`. On `bd` failure writes the error into the file and exits 1.

- [ ] **Step 1: Write tests** with a `bd` stub: `test_writes_sections` (file has both headings and stub output); `test_counts` (stdout `beads.md: 3 children, 1 open`); `test_bd_failure` (stub exits 1 → exit 1, file contains `bd failed`).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**; edit the four role files: replace `bd --readonly ...` reads with "read `<job folder>/beads.md`; it is the orchestrator's snapshot, taken just before you started". Add to `prose.test.sh`: `grep -l 'bd --readonly' ` over those four files → none.
- [ ] **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — `"Give sandboxed roles a Beads snapshot instead of bd access"`.

### Task 6: `run-codex` — no MCP, record how the run ended (findings fixes 2, 3)

**Files:**
- Modify: `factory/bin/run-codex`, `factory/bin/run-adversarial`
- Test: `factory/test/run-codex.test.sh`

**Interfaces:**
- Consumes: `models.json` entry (unchanged).
- Produces: `codex exec` gets `-c 'mcp_servers={}'` (verify with `codex exec --help` / a dry run that this empties servers; if the CLI needs another form, use it and note it in the header comment). Success line becomes `<key>: <model> (<effort>) exit <rc>, ended <event>. Last message: <path>`, where `<event>` is the `type` of the last parseable line of `$log.jsonl` (`none` if no line). Task 7 hooks usage in here.

- [ ] **Step 1: Write tests** with a `codex` stub that writes a scripted jsonl to stdout and records argv: `test_mcp_disabled` (argv contains `mcp_servers={}`); `test_ended_normal` (last event `turn.completed` → line contains `ended turn.completed`); `test_ended_truncated` (last line is half a JSON object, previous is `item.started` → `ended item.started`, exit code passes through as stub's 1).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** in `run-codex`; in `run-adversarial`, if the companion honours `CODEX_HOME`/config overrides, apply the same MCP-off override, otherwise leave a comment why not.
- [ ] **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — `"Run Codex roles without MCP servers and report how each run ended"`.

---

## Phase 2 — Spend and quota visibility

### Task 7: `usage-record codex`

**Files:**
- Create: `factory/bin/usage-record`, `factory/test/usage-record.test.sh`, `factory/test/fixtures/codex-{ok,multi-turn,aborted}.jsonl`, `factory/test/fixtures/codex-sessions/2026/10/19/rollout-…-<thread>.jsonl`
- Modify: `factory/bin/run-codex` (call it after codex exits), `factory/bin/run-adversarial` (call it with the `threadId` from the companion JSON)

**Interfaces:**
- Produces: `factory/bin/usage-record codex <job-folder> <log-prefix> <role> <exit-code>` → appends one line to `<job-folder>/usage.jsonl`, prints nothing, always exits 0. Line schema (spec Part 2, exact keys): `ts, role, provider, model, effort, stage, round, task, input, cached, cache_write, output, reasoning, duration_s, exit, ended, quota, log`. `provider/model/effort` from `models.json[role]`; `stage/round` from `job.json`; `task` = `job.json` task currently `in_progress` or null; tokens = sum over all `turn.completed.usage` (null if none); `duration_s` from the log-prefix timestamp to now; `quota` = `{"window": "weekly"|"5h"|"<n>m", "before": <first used_percent>, "after": <last used_percent>, "resets_at": <epoch>, "plan": <plan_type>}` from `rate_limits.primary` in the rollout whose filename ends `-<thread_id>.jsonl` under `${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}`, null if not found; `log` = log prefix relative to the job folder. On any internal error, the line has nulls and `"error": "<msg>"`.
- For `run-adversarial`: `usage-record codex <job> <log-prefix> reviewer-adversarial <rc> --thread <threadId>`; tokens come from the rollout's last `token_count.info.total_token_usage` when the log has no `turn.completed`.

- [ ] **Step 1: Write tests**: `test_single_turn` (fixture tokens `180312/155520/1272/24` → line values equal); `test_multi_turn_sums`; `test_quota_from_rollout` (fixture rollout `used_percent` 30.0 then 32.0, `window_minutes` 10080 → `{"window":"weekly","before":30,"after":32,…}`); `test_aborted_run` (no `turn.completed`, truncated last line → tokens null, `ended` = last good event type, exit 0, one line); `test_unwritable_never_fails` (job folder read-only → usage-record exits 0, stderr one line); `test_run_codex_appends` (stubbed codex → `usage.jsonl` has 1 line with `role":"builder"`).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.** Parse jsonl with `jq -R 'fromjson? // empty'` so truncated lines are skipped.
- [ ] **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — `"Record Codex token and quota usage per run"`.

### Task 8: `usage-record claude` and `usage-record session`

**Files:**
- Modify: `factory/bin/usage-record`, `factory/bin/autopilot` (record each session), `.claude/skills/factory/SKILL.md` (**Running a role**: after each `factory-agent` returns, run `factory/bin/usage-record claude <job-folder> <role>`; at **merged**, **needs-human**, **dropped**: `factory/bin/usage-record session <job-folder>`)
- Test: `factory/test/usage-record.test.sh`, `factory/test/fixtures/claude-project/<sid>.jsonl`, `…/<sid>/subagents/agent-x.jsonl`

**Interfaces:**
- `usage-record claude <job-folder> <role>`: under `${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/<slug>/` (slug = repo path with `/` and `.` → `-`), find `*/subagents/agent-*.jsonl` whose first user message starts `Role: factory/agents/<role>.md. Job folder: <job-folder>` and whose path is not already a `log` in `usage.jsonl`; record each. Tokens: assistant messages de-duplicated by `message.id`; `input` = Σ`input_tokens`+`cache_read_input_tokens`+`cache_creation_input_tokens`, `cached` = Σ`cache_read_input_tokens`, `cache_write` = Σ`cache_creation_input_tokens`, `output` = Σ`output_tokens`, `reasoning` = null; `model` from the sibling `.meta.json`; `quota` null; `ended` = `finished`/`unfinished` from meta.
- `usage-record session <job-folder> [<session-id>]`: role `orchestrator`, tokens from `<slug>/<sid>.jsonl` (main transcript only, never subagents, so nothing is counted twice). Without a session id: the most recently modified top-level transcript mentioning `factory/jobs/<job-id>/`. One line per session id (skip if already recorded).
- `factory/bin/autopilot` calls `usage-record session factory/jobs/<job> <sid>` after every session.

- [ ] **Step 1: Write tests**: `test_subagent_tokens_dedup` (fixture with each assistant message written twice → counts once); `test_subagent_not_recorded_twice` (run twice → 1 line); `test_matches_role_and_job` (a transcript for another job is ignored); `test_session_main_transcript_only`; `test_session_once_per_id`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**; update SKILL.md and `autopilot`.
- [ ] **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — `"Record Claude subagent and orchestrator usage per job"`.

### Task 9: `usage-summary`, `/factory status`, autopilot summary line

**Files:**
- Create: `factory/bin/usage-summary`, `factory/test/usage-summary.test.sh`
- Modify: `.claude/skills/factory/SKILL.md` (**/factory status** prints `usage-summary` output), `factory/bin/autopilot` (per-job line)

**Interfaces:**
- Produces: `factory/bin/usage-summary` → one line per job with a `usage.jsonl`: `<job-id> <stage>: <input>M in (<cached%> cached), <output>k out, <runs> runs[, FLAG <stage> <x>× median]`, then one line `quota: codex weekly <after>% (resets <date>)` from the newest record with quota, plus `claude: tokens only`. Flag rule: a job's token total for a stage ≥ 2× the median of that stage over jobs at `merged`/`dropped`, only when ≥ 3 such jobs exist.
- Autopilot per-job line: `autopilot: <job> (<bead>) <stage>, <tokens>M tokens, API-equivalent $<x>, session <sid>`.

- [ ] **Step 1: Write tests** with fixture job folders: `test_line_format`; `test_flag_needs_three_finished` (2 finished → no flag; 3 → flag at 2×); `test_quota_line_newest`; `test_no_usage_files` (prints only `quota: no data`).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — `"Summarise spend and quota for status and autopilot"`.

### Task 10: Dashboard

**Files:**
- Modify: `factory/dashboard.html`
- Test: manual (below), plus `prose.test.sh` `test_dashboard_reads_usage` (`grep -q "usage.jsonl" factory/dashboard.html`)

**Interfaces:**
- Consumes: `jobs/<id>/usage.jsonl` (fetched like `job.json`; missing → no usage), `settings.json` (`land` mode label), stages `resubmitted`, `dropped`.
- Shows: quota meters (Codex window %, reset time; "Claude: tokens only"); per job total tokens, runs, per-stage split, flag (same rule as Task 9, computed in JS); across jobs, totals and per-job averages per role and per model; per-run quota deltas labelled "approximate (account-wide meter)"; resubmitted jobs in their own group; `dropped` as an end state; land mode in the header.

- [ ] **Step 1: Add the test grep; run** — FAIL.
- [ ] **Step 2: Implement** in the existing fetch/render style (`fetchText`, per-job polling).
- [ ] **Step 3: Verify manually**: serve garmin-ai-coach's `factory/` (`python3 -m http.server -d ~/Development/garmin-ai-coach/factory 8765`) after copying in a `usage.jsonl` built by running `usage-record codex` over job 001's `.runs/*.jsonl`; open `http://localhost:8765/dashboard.html` with Playwright; screenshot shows job 001 with ≈7.4M Codex input tokens and a Codex weekly meter. Then run `factory/test/run` — pass.
- [ ] **Step 4: Commit** — `"Show spend and quota on the dashboard"`.

---

## Phase 3 — Human review and resubmission

### Task 11: `briefer` role

**Files:**
- Create: `factory/agents/briefer.md`
- Modify: `factory/models.json` (`"briefer": { "provider": "anthropic", "model": "opus" }`), `prose.test.sh`

**Interfaces:**
- Task `Brief k.` → writes `<job folder>/human-brief-<k>.md` with exactly `## Situation`, `## Decisions`, `## Out of scope` (content rules: spec Part 4 step 1, including APPROVE only for `escalated`/`merge-blocked` with all-PASS final round and every task closed per `beads.md`).
- Task `Write decision k.` + owner answers in the prompt → writes `<job folder>/human-<k>.md`, first line `APPROVE|REWORK|RESPEC|DROP`, then `## Owner answers` (verbatim), `## Instructions` (REWORK/RESPEC: scoped, code-level facts, "must not change"), `## Beads filed` (filled in by the session afterwards), `## Reason` (DROP).
- Reads: same inputs as `approver.md`, plus `human-*.md`, `beads.md`. Writes only those files. Finishes with one line per file, like every factory role.

- [ ] **Step 1: Add `prose.test.sh` checks** — briefer.md contains the three brief headings, both task names, and `APPROVE only`; models.json has `briefer`. Run — FAIL.
- [ ] **Step 2: Write `briefer.md`** in the style of `approver.md` (Where you work / Read / Write / Finish). Use job 001's `rework-1.md` as the quality bar it describes in prose (don't copy the file).
- [ ] **Step 3: Run** — pass. **Step 4: Commit** — `"Add the briefer role for human review"`.

### Task 12: `/factory review`, resubmission, resume, and binding owner decisions

**Files:**
- Modify: `.claude/skills/factory/SKILL.md` (new **/factory review [<job-id>]**; **job.json** gains `human_decision`, stages `resubmitted`, `dropped`; **/factory resume** handles `resubmitted`; **/factory approve** and **/factory rework** write `human-<k>.md` and resubmit; **Autopilot decision** honours owner limits; **/factory status** lists resubmitted and `needs-human` beads without jobs; description frontmatter lists `/factory review`), `factory/agents/{approver,autopilot,builder,spec-writer,planner}.md` (read `human-*.md`; owner scope is a hard limit; approver after owner APPROVE judges only the base-merge delta), `factory/autopilot-policy.md` (owner decisions bind), `README.md`
- Test: `prose.test.sh`

**Interfaces:**
- Consumes: briefer (Task 11), `land` exit 6 (Task 3), `beads-snapshot` (Task 5).
- Produces (for Task 13): a resubmitted job has `job.json` `stage: "resubmitted"`, `human_decision: "human-<k>.md"`, `situation: null`, `autopilot: true`; bead label `resubmitted` (no `needs-human`). `/factory resume <job-id>` on such a job removes `resubmitted` and acts per spec Part 4 ("The drain picks up resubmitted jobs"), with owner REWORK/RESPEC not incrementing `reworks`/`respecs`.
- Review session flow, exact: spec Part 4 steps 1–4, the `needs-human` beads-without-jobs section, and the end-of-review summary that offers `factory/bin/autopilot --watch` in the background when `pgrep -f factory/bin/autopilot` finds none.

- [ ] **Step 1: Add `prose.test.sh` checks**: SKILL.md has headings `## /factory review`, mentions `human_decision`, `resubmitted`, `dropped`, `.resume-claim`; `/factory approve` and `/factory rework` sections contain `resubmit` and no longer contain `Run **Merge**`/`Go to **Build**` directly; each of the five role files contains `human-*.md`; `autopilot.md` contains `may not RESPEC against`. Run — FAIL.
- [ ] **Step 2: Edit SKILL.md and role files.** Keep each new section in the voice and density of the surrounding sections.
- [ ] **Step 3: Run** — pass.
- [ ] **Step 4: Dry run** on a copy of garmin job 001 (copy its job folder into a scratch repo made by `mkrepo`, set `stage: "needs-human"`, `situation: "escalated"`): run `/factory review 001-…` in a Claude session there; check `human-brief-1.md` has the three sections, answering produces `human-1.md` and `job.json` `stage: "resubmitted"`, and the session ends without starting a build.
- [ ] **Step 5: Commit** — `"Add /factory review and resubmit decided jobs to the drain"`.

### Task 13: Drain picks up resubmitted jobs; `--watch`

**Files:**
- Modify: `factory/bin/autopilot`
- Test: `factory/test/autopilot.test.sh`

**Interfaces:**
- `factory/bin/autopilot [<count>] [--watch] [--budget <usd>]`. Each loop iteration: first the oldest job with `stage == "resubmitted"` it can claim with `mkdir factory/jobs/<id>/.resume-claim` (removed by a trap when that job's sessions end) → `/factory resume <id>. $headless`; else `next-bead`; else exit (`queue empty`) or, with `--watch`, sleep `AUTOPILOT_POLL_S` (default 60) and loop. End states for the inner loop: `merged`, `needs-human`, `dropped`.
- `.gitignore`: `factory/jobs/*/.resume-claim` is covered by `/factory/jobs/*`; nothing to add.

- [ ] **Step 1: Write tests** with a `claude` stub that sets the job's `stage` to `merged` (via `job-set`) and prints `{"session_id":"s","total_cost_usd":0}`, and a `bd` stub: `test_resubmitted_before_queue` (one resubmitted job and one queued bead → first stub call is `/factory resume <id>`); `test_claim_skips_claimed` (`.resume-claim` already exists → job not resumed); `test_claim_removed_after` (dir gone after the run); `test_dropped_is_end_state`; `test_watch_polls` (`--watch`, `AUTOPILOT_POLL_S=0`, a resubmitted job created after the first empty poll by the stub → picked up; test kills the drain after 2 iterations).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — `"Let the drain resume resubmitted jobs and keep watching"`.

---

## Phase 4 — Parallel autopilot

### Task 14: Beads stress test (hard gate)

**Files:**
- Create: `factory/bin/bd-stress`, (conditional) `factory/bin/bd-write`

**Interfaces:**
- `factory/bin/bd-stress [<writers>=4] [<rounds>=20]` → in a temp dir, `git init` + `bd init`, then N background writers each doing `<rounds>` iterations of: create a bead, `update --claim` (with `BEADS_ACTOR=w<i>`), add/remove label, comment, create 2 children, close children, close bead. Checks: zero non-zero exits, every created bead is closed with all its comments and labels as written. Prints `bd-stress: <N>×<rounds> ok` or `bd-stress: FAIL <count> errors, <count> lost writes; see <log>` and exits 1.
- If it fails: `factory/bin/bd-write <bd args...>` serialises with `mkdir .beads/.factory-write-lock` (retry 100ms, give up after 60s with exit 75) then execs `bd`; SKILL.md switches every orchestrator Beads **write** to `factory/bin/bd-write`. Re-run `bd-stress` with `BD=factory/bin/bd-write` → must pass.

- [ ] **Step 1: Implement `bd-stress`.**
- [ ] **Step 2: Run `factory/bin/bd-stress 4 20` and `factory/bin/bd-stress 8 20`.** Record the output in the commit message.
- [ ] **Step 3: If either fails**, implement `bd-write`, make `bd-stress` honour `BD=`, update SKILL.md, re-run both — Expected: `ok`.
- [ ] **Step 4: Commit** — `"Stress-test concurrent Beads writes"` (plus the wrapper if needed). **Do not start Task 15 until both runs print `ok`.**

### Task 15: Worker pool, autopilot actor, adopt acceptance

**Files:**
- Modify: `factory/bin/autopilot`, `.claude/skills/factory/SKILL.md` (**/factory adopt**, **Brownfield rules**, **Parallel jobs**, **/factory autopilot** drain text), `INSTALL.md`, `README.md`
- Test: `factory/test/autopilot.test.sh`

**Interfaces:**
- `factory/bin/autopilot [<count>] [--jobs N] [--watch] [--budget <usd>]`; `N` = `--jobs`, else `settings jobs 1`. Up to N workers, each running Task 13's loop body for one job at a time; `<count>` is total jobs across workers (shared counter: `mkdir`-guarded file under `factory/autopilot-runs/`). Every output line prefixed `[<job-id>]`. Ctrl-C/TERM: kill workers, print `autopilot: stopped. In flight: <job-id> (/factory resume <job-id>) …`. A failed worker doesn't stop others; exit 1 at the end if any failed.
- Claim before launch: `BEADS_ACTOR=factory-autopilot bd update <bead> --claim`; non-zero → ask `next-bead` again (excluding beads this run already tried). Sessions run with `BEADS_ACTOR=factory-autopilot` exported, and the prompt gains `Claimed for you by autopilot as factory-autopilot.`
- SKILL.md adopt path: an `in_progress` bead is accepted only when its assignee is `factory-autopilot` and the prompt says it was claimed for this run; any other `in_progress` bead is still refused.

- [ ] **Step 1: Write tests** (`claude` stub sleeps 1s then marks merged; `bd` stub implements claim with a `mkdir` per bead so the second claimer fails): `test_two_workers_run_concurrently` (2 beads, `--jobs 2` → both sessions overlap in time: second start < first end); `test_no_double_claim` (2 workers, 1 bead → exactly one `claude` call); `test_count_across_workers` (`--jobs 2 3` with 5 beads → exactly 3 jobs); `test_jobs_default_one` (no flag, no setting → never more than 1 session at once); `test_prefixed_output`; `test_interrupt_lists_in_flight` (send TERM mid-run → output contains `In flight:` and the job id); `test_actor_exported` (stub records `BEADS_ACTOR=factory-autopilot`).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — pass, shellcheck clean.
- [ ] **Step 5: Update SKILL.md, INSTALL.md, README.md**; `prose.test.sh` check that SKILL.md mentions `factory-autopilot` and `--jobs`. Run the full suite — pass.
- [ ] **Step 6: Commit** — `"Run several autopilot jobs at once"`.

### Task 16: End-to-end check in garmin-ai-coach

**Files:** none in ai-factory beyond fixes found.

- [ ] **Step 1:** Re-install into a fresh worktree of garmin-ai-coach per `INSTALL.md` (a straight copy plus `factory/settings.json` = `{"land":"pr","priority_labels":["lane:answers","lane:live","lane:platform","lane:ci"],"jobs":2}`). `diff -r` against garmin's current `factory/` shows only expected differences.
- [ ] **Step 2:** With the user's go-ahead (it opens real PRs and uses plan quota), run `factory/bin/autopilot --jobs 2 2` there. Expected: two jobs in flight, each `usage.jsonl` growing, dashboard shows both and a Codex weekly meter, each job ends `merged` or `needs-human`.
- [ ] **Step 3:** Report results to the user; fix anything found under a new task.
