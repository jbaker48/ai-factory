# Dashboard Board and Job Detail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dashboard with a four-lane board and a job detail view that tells each job's story (criteria, agent runs with prompt/output/changes, diffs), and make the factory record every prompt and keep task commits after merge.

**Architecture:** The read-only Node server (`factory/bin/dashboard`) gains three helper modules under `factory/dashboard/`: one for `.runs` (prompt and output files, tokens), one for git (task commits, diffs) and one that puts a job's runs in story order. The server also gets new GET endpoints for them. The page (`factory/dashboard.html`, still one file) keeps pure view logic in one `<script id="view">` block that a node test loads, and does its DOM work in a second script. The factory side gets a `prompt-record` helper, a prompt file from `run-adversarial`, and a `refs/factory/jobs/<job-id>` bookmark at Merge.

**Tech Stack:** Node (built-in modules only: `http`, `fs`, `path`, `child_process`, `vm`), bash + jq tests via `factory/test/lib.sh`, plain HTML/CSS/JS.

**Spec:** `docs/superpowers/specs/2026-10-20-dashboard-board-and-detail-design.md`

## Global Constraints

- No new dependencies and no build step. The page stays one file, `factory/dashboard.html`. The server requires only Node built-ins and the local `factory/dashboard/*.js` modules.
- The server listens on `127.0.0.1` only and answers GET only (405 otherwise).
- `git` is run with `child_process.execFile('git', ['-C', repo, ...])`, never a shell. Only the subcommands `log`, `show`, `diff` are used. Every `show`/`diff` passes `--no-ext-diff --no-color`. Output is capped at 2 MB (`2 * 1024 * 1024`; tests override it with env `FACTORY_DASHBOARD_DIFF_CAP=<bytes>`). The repo is `path.resolve(factory, '..')`.
- From `.runs/` only `<stem>.prompt.md` and `<stem>.last.md` are served, where `<stem>` matches `^\d{8}-\d{6}-[a-z][a-z0-9-]*$`. `.jsonl`, `.stderr`, `.json`, `.browser`, `checks.log` are never served.
- Prompt file stamps use `date +%Y%m%d-%H%M%S` (local time), the same as `run-codex`, so Claude and Codex runs sort together. (The spec says "UTC" but also "the same naming `run-codex` uses"; the existing files are local time, so this plan keeps the naming.)
- Tokens only, no dollars. A run with no token source shows `tokens not recorded`, never `0`.
- Visual: light theme by default (white cards on a pale grey board), dark theme behind a toggle. One blue accent, used only for the selected card and the current stage. Green = pass/done, amber = waiting/pending, red = changes/blocked, and no other colours. No glows, gradients, glass, grid backgrounds, decorative icons, pill-everything, or uppercase wide-tracked labels. Radius small and consistent, with a shadow only on the open detail. System UI font for text; monospace only for ids, branches, prompts and diffs. Motion only for the detail opening, sections expanding, and a slow pulse on a Running stage section that holds a job. Turn all motion off under `prefers-reduced-motion`. Antislop dials ENERGY 1 / RHYTHM 2 / MOTION 1.
- `factory/test/prose.test.sh` keeps passing. `dashboard.html` must still contain `usage.jsonl`, `retro_pr`, `retro_factory_pr`, `'retro.md'` and `` `/factory review ${job.id}` ``.
- Code style: match the existing files. JS uses `'use strict'`, 2-space indent, no semicolons, and a header comment with usage. Bash uses `set -uo pipefail` and a usage header comment. Tests use `test_*` functions and `finish`.
- Run the full suite with `factory/test/run`.

## Review Focus

1. **Early or odd jobs.** A job in `spec` with no `spec.md`, no `plan.json`, no `.runs/` and no branch, or a factory that is not inside a git repo at all, gets a detail view that says what is missing. Every endpoint returns 200 with nulls, never 500. Task 2 and Task 3 tests.
2. **Task id prefixes.** Commit `(garmin-ai-coach-903.10)` must never match task `garmin-ai-coach-903.1`. Task 2 test.
3. **Hostile text.** Prompts, outputs, spec text and diff lines are full of `<`, `&`, backticks and HTML. Everything must render as text and never execute. Task 5 view test on `markdown` and `parseDiff`.
4. **Polling while reading.** The board re-polls every 2 s while a detail is open. Open sections, scroll position and focus in the detail must survive a poll; the detail re-renders only when the job's `updated` changes, and keeps open sections open when it does. Task 7, checked in the browser.
5. **Runs that died.** A `.runs` stem with a prompt but no `.jsonl`/`.last.md`, or a `.jsonl` that ends on a truncated line, is still listed in order with tokens `null`. Task 1 test.

---

### Task 1: Runs, prompt files and token fallback on the server

**Files:**
- Create: `factory/dashboard/runs.js`
- Modify: `factory/bin/dashboard` (servable rule, `state()`, new route; update the header comment)
- Test: `factory/test/dashboard.test.sh`

**Interfaces:**
- Produces, `factory/dashboard/runs.js` (`module.exports = { STEM, stageOfKey, listRuns, derivedUsage }`):
  - `STEM`: the regex `/^\d{8}-\d{6}-[a-z][a-z0-9-]*$/`.
  - `stageOfKey(key: string) -> string|null`: `spec-writer`→`spec`, `planner`→`plan`, `builder`/`builder-escalation`→`build`, `reviewer-*`→`review`, `approver`→`approve`, `autopilot`→`autopilot`, `briefer`→`needs-human`, `retro`→`retro`, and anything else → `null`.
  - `listRuns(dir: string, job: object, usage: object[]) -> Run[]`, where `Run` is
    `{ id, stamp, key, stage, task, round, decision, prompt, last, model, tokens, tokens_from }`:
    - `id` is the stem (`20261019-173747-builder`), `stamp` its first 15 characters, `key` the rest.
    - `prompt` / `last` are `.runs/<id>.prompt.md` / `.runs/<id>.last.md` when the file exists, else `null`.
    - `task`, `round` and `decision` are parsed from the last non-empty line of the prompt file: `Build task <id>.` → task, `Review round <N>.` or `Final round: <N>.` → round, `Decision file: <file>.` → decision. If the prompt doesn't give them, they come from the matching usage record's `task`/`round`. Then a `review`-stage run that still has no round takes the round of the nearest earlier `review`-stage run. Otherwise `null`.
    - `tokens` is `{ input, cached, output, reasoning }`. It comes from the usage record whose `log` is `.runs/<id>` (`tokens_from: 'usage'`). Without one, it is the sum of `usage` over every `turn.completed` line in `.runs/<id>.jsonl`, skipping lines that don't parse (`input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`; `tokens_from: 'derived'`). Otherwise `null`/`null`. `model` is the usage record's `model`, else `null`.
    - Runs come from every distinct stem in `.runs/` (any extension). Claude usage records (whose `log` does not start with `.runs/`) are matched as follows. A record attaches to the latest stem with the same `key` as its `role`, a stamp at or before the record's `ts` (compared as local time), and no usage yet. If there is no such stem, it becomes its own run: `id` is `usage-<line index>`, `stamp` is its `ts` as local `yyyymmdd-HHMMSS`, `key` is its `role`, and `prompt`/`last` are null.
    - Sorted by `stamp`, then `key`.
  - `derivedUsage(dir: string, job: object) -> object[]`: for a job folder with **no** `usage.jsonl`, one record per run that has derived tokens. Each record is `{ ts, role, stage, round, task, input, cached, output, reasoning, model: null, log: '.runs/<id>', derived: true }`, with `ts` the stamp as an ISO string (local time → `toISOString()`).
- Produces, server:
  - `/api/state` jobs carry `usage: readUsage(dir)` as before. When `usage.jsonl` is absent they carry `usage: derivedUsage(dir, job)` and `usage_derived: true` instead.
  - `GET /api/runs?job=<id>` → `Run[]` (404 `{error:'no such job'}` for a bad id).
  - `GET /api/file?job=<id>&path=.runs/<stem>.prompt.md|.last.md` is served. `/api/files` still lists no `.runs/` files.

- [ ] **Step 1: Write the failing tests** in `factory/test/dashboard.test.sh`. Extend the fixture: in `001-a`, `.runs/20261019-173747-builder.{prompt.md,last.md,jsonl,stderr}`, where the prompt ends with the line `Job folder: x. Build task t.1.` and the jsonl has two `turn.completed` lines (input 100/50, cached 80/40, output 10/5, reasoning 4/2) plus one truncated line. Also add `.runs/20261019-175425-reviewer-security.prompt.md` ending `… Review round 1.`, `.runs/20261019-175427-reviewer-adversarial.json`, and `.runs/20261019-180000-builder.prompt.md` alone (a run that died). Add a job `003-c` with `.runs` but no `usage.jsonl`. New cases:

```bash
test_runs() {
  local r; r=$(get '/api/runs?job=001-a')
  assert_eq "20261019-173747-builder 20261019-175425-reviewer-security 20261019-175427-reviewer-adversarial 20261019-180000-builder" \
    "$(jq -r '[.[].id] | join(" ")' <<<"$r")" "runs in stamp order, died run included"
  assert_eq "t.1 build" "$(jq -r '.[0] | "\(.task) \(.stage)"' <<<"$r")" "task parsed from prompt"
  assert_eq "1 1" "$(jq -r '[.[1].round, .[2].round] | join(" ")' <<<"$r")" "review round parsed and inherited"
  assert_eq "150 derived" "$(jq -r '.[0] | "\(.tokens.input) \(.tokens_from)"' <<<"$r")" "tokens derived from turn.completed"
  assert_eq "null null" "$(jq -r '.[3] | "\(.tokens) \(.last)"' <<<"$r")" "died run has no tokens or output"
}
test_runs_served() {
  local u="http://127.0.0.1:$PORT/api/file?job=001-a&path=.runs/20261019-173747-builder"
  assert_eq 200 "$(code "$u.prompt.md")" "serves .prompt.md"
  assert_eq 200 "$(code "$u.last.md")" "serves .last.md"
  assert_eq 404 "$(code "$u.jsonl")" "refuses .jsonl"
  assert_eq 404 "$(code "$u.stderr")" "refuses .stderr"
  assert_eq 404 "$(code "http://127.0.0.1:$PORT/api/file?job=001-a&path=.runs/../job.json")" "no traversal through .runs"
}
test_derived_usage() {
  local s; s=$(get /api/state)
  assert_eq "true true" "$(jq -r '.jobs[] | select(.id == "003-c") | "\(.usage_derived) \(.usage[0].derived)"' <<<"$s")" "usage derived without usage.jsonl"
}
```

Keep the existing `no dot folders` case (`.runs/log.md` → 404: not a stem) and its file-list case.

- [ ] **Step 2: Run `bash factory/test/dashboard.test.sh`.** Expect FAIL on the new cases.
- [ ] **Step 3: Implement `factory/dashboard/runs.js`** as in Interfaces. In the server, extend `servable(rel)` to accept `.runs/<stem>.prompt.md` and `.runs/<stem>.last.md` (one level only, and still checked with realpath). Add the `/api/runs` route and the `state()` fallback.
- [ ] **Step 4: Run `bash factory/test/dashboard.test.sh`.** Expect all pass.
- [ ] **Step 5: Commit** `dashboard: list agent runs, serve prompts, derive tokens from Codex logs`.

### Task 2: Task commits and diffs on the server

**Files:**
- Create: `factory/dashboard/git.js`
- Modify: `factory/bin/dashboard` (routes, header comment)
- Test: `factory/test/dashboard-git.test.sh` (new; uses `mkrepo` from `lib.sh`, so the factory sits inside a real repo)

**Interfaces:**
- Consumes: `jobDir(id)` and `readJSON` from the server. `settings.json` `land` (`local` → base `main`, else `origin/main`).
- Produces, `factory/dashboard/git.js` (`module.exports = { changes, diff }`; everything async, and it never throws for "not a git repo" or a missing ref):
  - `changes(repo: string, id: string, job: object) -> Promise<Changes>`, where `Changes` is
    `{ source: 'branch'|'bookmark'|'remote'|null, tasks: { [taskId]: { commit, subject, files: [{ path, added, removed }] } }, job: { kind: 'landing'|'branch'|null, commit: string|null, files: [...], added: number, removed: number } }`.
    - The job ref is the first that `git log -1 --format=%H <ref> --` resolves among `refs/heads/factory/<id>` (`branch`), `refs/factory/jobs/<id>` (`bookmark`) and `refs/remotes/origin/factory/<id>` (`remote`).
    - A task's commit is the newest commit in `git log --format=%H%x1f%s -n 1000 <ref> --` whose subject ends with `(<task id>)` exactly. Tasks without one are left out of `tasks`.
    - For a `merged` job the landing commit is found on `<base>`: the subject ends with `(#<n>)` where `<n>` is the number at the end of `job.pr`, or else it equals `Merge branch 'factory/<id>'`, or else it starts with `<bead>: `. Its change is `git diff --numstat <hash>^1 <hash>` (`kind: 'landing'`). For any other job with a ref, the change is `git diff --numstat <base>...<ref>` (`kind: 'branch'`).
    - In numstat, a binary file's `-` becomes `null`.
  - `diff(repo, id, job, { task?: string, commit?: string }) -> Promise<{ status: number, text: string, truncated: boolean }>`:
    - `task`: 400 if it is not one of `job.tasks[].id`, 404 `Task commits are no longer available for this job` if it has no commit, else `git show --format= --no-ext-diff --no-color <hash>`.
    - `commit`: 400 unless it matches `^[0-9a-f]{7,40}$`, 404 unless it is a prefix of one of this job's task commits or its landing commit.
    - Neither: the whole-job diff (`git diff --no-ext-diff --no-color <hash>^1 <hash>` for landing, `<base>...<ref>` for branch), or 404 `No diff for this job yet`.
    - Output longer than the cap is cut at the cap, with `truncated: true` and `\n… diff truncated at <n> MB\n` appended.
- Produces, server: `GET /api/changes?job=<id>` → `Changes` JSON. `GET /api/diff?job=<id>[&task=<id>|&commit=<hex>]` → `text/plain`, with header `x-diff-truncated: 1` when cut, or JSON `{error}` with the status from `diff`.

- [ ] **Step 1: Write the failing tests** in `factory/test/dashboard-git.test.sh`. Use `mkrepo`. Write `factory/jobs/001-a/job.json` with `stage: "review"`, `bead: "b-1"` and tasks `b-1.1`, `b-1.10`. Create branch `factory/001-a` with commits `add a (b-1.10)` touching `a.txt` and `add b (b-1.1)` touching `b.txt` with 3 lines. Add `settings.json` `{"land":"local"}`. Start the server from that copy. Cases:

```bash
test_task_commits() {
  local c; c=$(get '/api/changes?job=001-a')
  assert_eq branch "$(jq -r .source <<<"$c")" "finds the job branch"
  assert_eq "b.txt 3" "$(jq -r '.tasks["b-1.1"].files[0] | "\(.path) \(.added)"' <<<"$c")" "b-1.1 is not matched by (b-1.10)"
  assert_eq "a.txt" "$(jq -r '.tasks["b-1.10"].files[0].path' <<<"$c")" "b-1.10 has its own commit"
  assert_eq "branch 2" "$(jq -r '.job | "\(.kind) \(.files | length)"' <<<"$c")" "whole job against main"
  assert_contains "$(get '/api/diff?job=001-a&task=b-1.1')" '+++ b/b.txt' "task diff"
}
test_bookmark_after_branch_deleted() {
  (cd "$REPO" && git update-ref refs/factory/jobs/001-a factory/001-a && git branch -D factory/001-a) >/dev/null
  assert_eq bookmark "$(get '/api/changes?job=001-a' | jq -r .source)" "falls back to refs/factory/jobs"
  assert_contains "$(get '/api/diff?job=001-a&task=b-1.1')" '+++ b/b.txt' "task diff from the bookmark"
}
test_merged_landing() { : # stage merged, pr ".../pull/7", a squash commit "b-1: A (#7)" on main → .job.kind == "landing" and its diff
}
test_refuses() {
  local u="http://127.0.0.1:$PORT/api/diff?job=001-a"
  assert_eq 400 "$(code "$u&task=nope")" "unknown task id"
  assert_eq 400 "$(code "$u&commit=HEAD")" "commit must be hex"
  assert_eq 400 "$(code "$u&commit=--output=x")" "no option injection"
  assert_eq 404 "$(code "$u&commit=deadbeef")" "commit not in this job"
  assert_eq 404 "$(code "http://127.0.0.1:$PORT/api/diff?job=../x")" "bad job id"
}
test_truncated() { : # restart with FACTORY_DASHBOARD_DIFF_CAP=50 → header x-diff-truncated: 1, body ends "diff truncated"
}
test_not_a_repo() { : # a factory copy outside any repo → /api/changes 200 with source null, /api/diff 404
}
test_no_commit() { : # a task with no commit → /api/diff?task= 404 with "no longer available"
}
```

Fill in the stub bodies (`:`) in the same style. Each assertion is named in its comment.
- [ ] **Step 2: Run `bash factory/test/dashboard-git.test.sh`.** Expect FAIL.
- [ ] **Step 3: Implement `factory/dashboard/git.js`** and the two routes. Use `execFile` with `{ maxBuffer: cap + 1 }`. A `maxBuffer` error still hands back the stdout read so far, so slice that to the cap. A non-zero git exit while resolving a ref means "not found". Any other git failure goes back as `{error}` with 500.
- [ ] **Step 4: Run `bash factory/test/dashboard-git.test.sh && bash factory/test/dashboard.test.sh`.** Expect all pass.
- [ ] **Step 5: Commit** `dashboard: task commits, job diff and bookmark fallback, read-only git`.

### Task 3: Job detail assembly on the server

**Files:**
- Create: `factory/dashboard/detail.js`
- Modify: `factory/bin/dashboard` (route, header comment)
- Test: `factory/test/dashboard.test.sh`

**Interfaces:**
- Consumes: `listRuns` and `stageOfKey` (Task 1).
- Produces, `factory/dashboard/detail.js` (`module.exports = { detail }`): `detail(dir: string, job: object, usage: object[]) -> Detail`, where `Detail` is
  `{ criteria: Criterion[]|null, criteria_note: string|null, out_of_scope: string|null, plan: { status, tasks: [{ key, title, covers, id }] }|null, timeline: Group[] }`.
  - **Criteria** come from the `## Acceptance criteria` section of `spec.md`, up to the next `## ` heading. Each top-level item is a line matching `^(\d+)\. `. The lines after it (indented, nested lists, wrapped text) belong to it until the next top-level item. A criterion is `{ n, text, tasks: [{ id, title, status }] }`, where `text` is the item's markdown without its `N. ` prefix. `tasks` are the job tasks whose plan task's `covers` includes `n`. Plan task `i` maps to `job.tasks[i]` (plan order = bead child order), unless a job task has a `key` equal to the plan task's `key`. When there is no `spec.md`, `criteria` is `null` and `criteria_note` is `No spec yet.`. When there is no such section, it is `null` with `The spec has no Acceptance criteria section.`.
  - **out_of_scope** is the raw markdown body of `## Out of scope`, or `null`.
  - **plan** is `plan.json` with each task's mapped `id`, or `null` when the file is missing or invalid.
  - **timeline**: each run gets `output`, the first of these that exists. `spec-writer`→`spec.md`. `planner`→`plan.json`. `build` with a task→`build/<task>.md`. `reviewer-<k>` with round N→`round-N/review-<k>.md`. `approver` with round N→`decision-round<N>.md`, or `decision.md` for the job's last approver run. `autopilot` with a decision→that file. Otherwise `run.last`. Then the runs are cut into groups in stamp order:
    - `{ kind: 'spec', runs }` and `{ kind: 'plan', runs }`: runs of that stage.
    - `{ kind: 'build', runs }`: build runs before the first review-stage run.
    - For each round N found on any run: `{ kind: 'round', round: N, runs }` holds its reviewer runs and its approver run. Then `{ kind: 'between', after: N, runs, notes }` holds every other run after round N's last run and before round N+1's first. `notes` are `[{ path }]` for `rework-<k>.md`, `human-<k>.md` and `human-brief-<k>.md` whose mtime falls in that span (or in the last `between` when none does). The last round has no `between` unless something follows it.
    - `{ kind: 'approve', runs, output: 'decision.md'|null }`: the job's last approver run, moved out of its round.
    - `{ kind: 'merge', pr: job.pr|null, stage: job.stage }` when `stage` is `merged` or `dropped`.
    - Spec, plan, build, approve and merge groups are left out when they would be empty.
- Produces, server: `GET /api/detail?job=<id>` → `Detail`.

- [ ] **Step 1: Write the failing tests.** Extend the `001-a` fixture with a `spec.md` that has 3 criteria, where criterion 2 has a nested `   - sub` line, plus `## Out of scope`. Add `plan.json` with `T1 covers [1,2]` and `T2 covers [3]`, and `job.json` tasks `t.1`, `t.2`. Add `.runs` for rounds 1 and 2 (reviewer + approver), an autopilot run between them with `Decision file: autopilot-1.md.`, and `rework-1.md` with an mtime in that gap (`touch -t`). Add job `004-d` with no `spec.md`.

```bash
test_detail() {
  local d; d=$(get '/api/detail?job=001-a')
  assert_eq 3 "$(jq '.criteria | length' <<<"$d")" "three criteria"
  assert_contains "$(jq -r '.criteria[1].text' <<<"$d")" '- sub' "nested lines stay with their criterion"
  assert_eq "t.1" "$(jq -r '[.criteria[1].tasks[].id] | join(" ")' <<<"$d")" "covering tasks by plan order"
  assert_eq "spec plan build round between round approve" "$(jq -r '[.timeline[].kind] | join(" ")' <<<"$d")" "groups in story order"
  assert_eq "autopilot-1.md rework-1.md" "$(jq -r '.timeline[4] | [.runs[0].output, .notes[0].path] | join(" ")' <<<"$d")" "between round 1 and 2"
  assert_eq "round-1/review-security.md" "$(jq -r '.timeline[3].runs[0].output' <<<"$d")" "reviewer output path"
}
test_detail_no_spec() {
  local d; d=$(get '/api/detail?job=004-d')
  assert_eq "null No spec yet." "$(jq -r '"\(.criteria) \(.criteria_note)"' <<<"$d")" "missing spec said plainly"
  assert_eq "[]" "$(jq -c .timeline <<<"$d")" "no runs, empty timeline"
}
```

- [ ] **Step 2: Run `bash factory/test/dashboard.test.sh`.** Expect FAIL.
- [ ] **Step 3: Implement `detail()`** and the route.
- [ ] **Step 4: Run `bash factory/test/dashboard.test.sh`.** Expect all pass.
- [ ] **Step 5: Commit** `dashboard: job detail with criteria, coverage and runs in story order`.

### Task 4: Record every prompt; keep task commits after merge

**Files:**
- Create: `factory/bin/prompt-record`
- Modify: `factory/bin/run-adversarial` (save the focus prompt), `.claude/skills/factory/SKILL.md` (**Running a role → anthropic**, **Merge** exit 0, **Files**), `README.md` (file list, and the `factory/dashboard/` modules from Tasks 1–3)
- Test: `factory/test/prompt-record.test.sh` (new), `factory/test/run-adversarial.test.sh` (new), `factory/test/prose.test.sh`

**Interfaces:**
- Produces: `factory/bin/prompt-record <job-folder> <key> <prompt>`. It looks up `<key>` in `factory/models.json` and its `agent` (default: the key), then writes `<job-folder>/.runs/<date +%Y%m%d-%H%M%S>-<key>.prompt.md` as `{ cat factory/agents/<agent>.md; printf '\n\n---\n\n%s\n' "$prompt"; }`, byte for byte the shape `run-codex` writes. It prints the path. Exit codes: 2 for wrong arguments, an unknown key or a missing role file; 1 if it cannot write.
- Produces: `run-adversarial` writes `$log.prompt.md` containing `$focus` before calling the companion (`$log` is its existing `.runs/<ts>-reviewer-adversarial` prefix).

- [ ] **Step 1: Write the failing tests.**
  - `prompt-record.test.sh`: with a copy of the factory, `prompt-record "$J" reviewer-code "Job folder: x. Review round 2."` prints a path matching `.runs/[0-9]{8}-[0-9]{6}-reviewer-code.prompt.md`. The file starts with the first line of `agents/reviewer-code.md` and ends with `---\n\nJob folder: x. Review round 2.`. `builder-escalation` reads `agents/builder.md`. An unknown key or a missing argument gives exit 2.
  - `run-adversarial.test.sh`: `CODEX_COMPANION` points to a stub `.mjs` that prints `{"threadId":null,"result":{"verdict":"approve","summary":"ok","findings":[],"next_steps":[]}}`. The real `usage-record` runs too (it is called by path and always exits 0). After `run-adversarial "$J" "$REPO" 1`, `.runs/*-reviewer-adversarial.prompt.md` exists and contains the spec's first line.
  - `prose.test.sh`: SKILL.md contains `factory/bin/prompt-record <job folder> <key>`, and contains `git update-ref refs/factory/jobs/<job-id> factory/<job-id>` on a line before `git branch -D factory/<job-id>` (compare `grep -n` line numbers).
- [ ] **Step 2: Run the three test files.** Expect FAIL.
- [ ] **Step 3: Implement.**
  - Add `factory/bin/prompt-record` (header comment in the style of `run-codex`).
  - Save the prompt in `run-adversarial`.
  - SKILL.md **anthropic** bullet: before spawning, run `factory/bin/prompt-record <job folder> <key> "<the prompt>"` with the exact prompt line that will be sent, and skip it for the importer.
  - SKILL.md **Merge** exit 0 block: add `git update-ref refs/factory/jobs/<job-id> factory/<job-id>` as the line before `git branch -D`. Add one sentence: it is a local bookmark, never pushed, so the dashboard can show task diffs after merge.
  - SKILL.md **Files**: `.runs/` holds "Codex and Claude prompts, Codex logs". Add a line for `refs/factory/jobs/<job-id>`.
  - README: list `bin/prompt-record` and `dashboard/{runs,git,detail}.js`.
- [ ] **Step 4: Run `factory/test/run`.** Expect `all test files passed`.
- [ ] **Step 5: Commit** `factory: record Claude and adversarial prompts; bookmark job branches at merge`.

### Task 5: Page, part 1: the board

**Files:**
- Modify: `factory/dashboard.html`. Rewrite the board and keep what is listed below. Replace the design-notes comment at the top with the new direction, one line per decision.
- Test: `factory/test/dashboard-view.test.sh` (new). It reads `dashboard.html`, extracts the contents of `<script id="view">…</script>`, runs it with `node -e` in `vm.runInNewContext({})`, and asserts on the functions below.

**Interfaces:**
- Keep and reuse: `fmtTok`, `stageTotals`, `runawayFlags`, `newestQuotas`, `groupSpend`, `quotaMeter`, `spendTable`, `markdown`, `inline`, the theme toggle with its `localStorage` wrappers, and the 2 s `poll()` of `/api/state`. Move the pure ones (`fmtTok`, `stageTotals`, `runawayFlags`, `newestQuotas`, `markdown`, `inline`, and the new functions below) into `<script id="view">`. That block must not touch `document` or `window`.
- Produces, in `<script id="view">`:
  - `laneOf(stage) -> 'running'|'deciding'|'needs'|'done'` (`spec|plan|build|review` → running, `approve|autopilot` → deciding, `needs-human|resubmitted` → needs, `merged|dropped` → done).
  - `doneOrder(jobs) -> jobs`: newest `updated` first.
  - `jobTokens(job) -> number|null`: the sum over `usage`, or `null` when there are no records.
  - `escapeHtml(s) -> string`. `markdown` and `inline` escape all source text before adding their own tags.
- Board behaviour (from the spec, **Board**):
  - Four lanes: Running, Deciding, Needs you, Done.
  - Running has sections Spec, Plan, Build, Review, each showing `none` when empty. The section holding a job gets the slow pulse.
  - Done shows 10 jobs, then a `Show all N` button.
  - Every card is a `<button>` with: job number, bead, feature (clamped to 2 lines), and total tokens (`tokens not recorded` when `jobTokens` is null, `(from Codex logs)` when `usage_derived`). Stage-specific lines:
    - spec/plan: the model from `models.json` (`spec-writer` / `planner`) and `writing spec.md` / `writing the plan`.
    - build: the builder model, `task k of n`, and task dots.
    - review: `round N` and five reviewer boxes (sec, code, ux, ui, adv) as pass, changes or dashed pending.
    - approve/autopilot/needs-human/resubmitted: a marker word plus the last round's result. Needs-human shows `situation` in words (`plan-blocked` → "Plan blocked", …) and the hint `` `/factory review ${job.id}` ``.
    - merged/dropped: outcome, task count, PR link.
  - Runaway flags from `runawayFlags` on the card.
  - Header: "Factory" as text, quota meters, land mode, the collapsible spend summary, theme toggle, and `Updated HH:MM:SS`. When a poll fails, keep the last board and show `Server unreachable, showing data from HH:MM:SS`. `problems` are listed under the header.
  - Empty state: `No jobs yet. Start one with /factory <feature>`.
  - Layout: lanes stack under 900px, and there is no horizontal page scroll at 390px.
  - Clicking a card or pressing Enter on it calls `openDetail(id)`, which is a stub that sets `location.hash = 'job=' + id` until Task 6.

- [ ] **Step 1: Write the failing view tests:**

```bash
v() { node -e "$VIEW_HARNESS" "$1"; }   # the harness prints JSON.stringify(eval(argv[1])) inside the vm context
test_lanes() {
  assert_eq '["running","running","deciding","needs","needs","done"]' \
    "$(v '["spec","review","autopilot","needs-human","resubmitted","dropped"].map(laneOf)')" "stage to lane"
}
test_escape() {
  assert_eq false "$(v 'markdown("<img src=x onerror=alert(1)> `<b>` **&**").includes("<img")')" "markdown escapes html"
  assert_eq false "$(v 'inline("<script>").includes("<script")')" "inline escapes html"
}
test_tokens() {
  assert_eq null "$(v 'jobTokens({usage: []})')" "no records is null, not 0"
  assert_eq 15 "$(v 'jobTokens({usage: [{input: 10, output: 5}]})')" "sums records"
}
test_done_order() {
  assert_eq '["b","a"]' "$(v 'doneOrder([{id:"a",updated:"2026-10-19T01:00:00Z"},{id:"b",updated:"2026-10-20T01:00:00Z"}]).map(j=>j.id)')" "newest first"
}
```

Before writing `jobTokens`, read how the existing `tokens(r)` counts a record (which fields it sums) and use the same rule.
- [ ] **Step 2: Run `bash factory/test/dashboard-view.test.sh`.** Expect FAIL.
- [ ] **Step 3: Implement** the view functions and the board.
- [ ] **Step 4: Run `factory/test/run`.** Expect all pass, prose tests included.
- [ ] **Step 5: Commit** `dashboard: four-lane board with stage sections`.

### Task 6: Page, part 2: detail panel, header, criteria, files

**Files:**
- Modify: `factory/dashboard.html`
- Test: `factory/test/dashboard-view.test.sh`

**Interfaces:**
- Consumes: `/api/state` job objects, `/api/detail` (Task 3), `/api/changes` (Task 2), `/api/files`, `/api/file`.
- Produces, in `<script id="view">`: `hashJob(hash: string) -> string|null`. It parses `#job=<id>` and returns null for anything that doesn't match `^[A-Za-z0-9][A-Za-z0-9._-]*$`.
- Produces, DOM: `openDetail(id)`, `closeDetail()`, `toggleExpand()`.
- Behaviour (from the spec, **Job detail**):
  - The panel opens to the right of the board, and the board stays visible. An expand button widens it to the full window. Escape or a close button closes it and returns focus to the card. The URL hash holds `job=<id>`, so a reload reopens it. Under 900px the panel is full screen.
  - Header: job id, bead, branch (mono), stage, `round N`, `n tasks`, total tokens, and run count from `/api/runs` length (or `timeline` run count). Links: PR, Retro PR (`retro_pr`), Factory retro PR (`retro_factory_pr`). The job total change `2 files, +184 −3` comes from `/api/changes` `.job` and is a button that opens the whole-job diff (rendered by Task 7; until then it opens `/api/diff?job=` text in a `<pre>`).
  - Left column, **Acceptance criteria**: `criteria` rendered with `markdown`, each followed by its tasks as `id` plus a status word with its status colour. When `criteria` is null, show `criteria_note`. `out_of_scope` sits in a collapsed `<details>`.
  - A **Files** toggle in the header lists `/api/files` (sorted by the old `fileRank`, which keeps `'retro.md'`). Each file opens rendered in place.
  - Loading and error: each fetch shows `Loading…` in its slot, or `Could not load <thing>: <error>`.

- [ ] **Step 1: Write the failing view test:**

```bash
test_hash() {
  assert_eq '["001-a",null,null]' "$(v '["#job=001-a","#job=../x","#other"].map(hashJob)')" "hash parsing"
}
```

- [ ] **Step 2: Run it.** Expect FAIL.
- [ ] **Step 3: Implement** the panel.
- [ ] **Step 4: Run `factory/test/run`.** Expect all pass.
- [ ] **Step 5: Commit** `dashboard: job detail panel with criteria and coverage`.

### Task 7: Page, part 3: runs timeline, prompt/output/changes, diffs

**Files:**
- Modify: `factory/dashboard.html`
- Test: `factory/test/dashboard-view.test.sh`

**Interfaces:**
- Consumes: `Detail.timeline` (Task 3), `Changes.tasks` (Task 2), `/api/file`, `/api/diff`.
- Produces, in `<script id="view">`:
  - `foldTimeline(groups) -> groups`. When there are more than 2 `round` groups, everything from the first `between` through the second-to-last `round` and the `between` before it is replaced by one `{ kind: 'fold', label, groups }`. With R rounds the label is `Rework cycles 1 to ${R-2} (rounds 2 to ${R-1})`, or `Rework cycle 1 (round 2)` when R = 3. In job 001 (8 rounds) that leaves round 1, the fold, the `between` after round 7, and round 8 visible.
  - `parseDiff(text) -> [{ path, added, removed, lines: [{ type: 'hunk'|'add'|'del'|'ctx'|'meta', text }] }]`, one entry per `diff --git` block. `path` is the `+++ b/` path, or the `--- a/` path for a deletion.
  - `planTasks(plan) -> string`: markdown listing each plan task as `` `key` title (covers 1, 2) ``.
- Behaviour (from the spec, **Right column: agent runs**):
  - Groups are headed Spec, Plan (with `planTasks`), Build, `Round N`, `Between rounds N and N+1`, Approve, Merge. A fold renders as one button that expands in place.
  - Each run is a row showing role, model, tokens (`fmtTok`, or `tokens not recorded`) and time (from `stamp`). It has up to three toggles, all closed by default and loaded lazily when opened:
    - **Prompt**: `run.prompt` in a mono `<pre>`, or `No prompt recorded for this run`.
    - **Output**: `run.output`, rendered with `markdown` (`plan.json` via `planTasks`), or `No output recorded`.
    - **Changes**, for build runs with a task: the files in `Changes.tasks[task].files` with `+a −r`. Each expands to its part of `/api/diff?job=&task=`, parsed with `parseDiff`. When the task has no entry, show `Task commits are no longer available for this job`.
  - `between` notes (rework, human and brief files) render as rows with an Output toggle only.
  - Diffs render in their own scroll box: mono, add lines green-tinted, del lines red-tinted, hunk lines muted. A `x-diff-truncated` response shows `Diff truncated at 2 MB` above the box. The header's whole-job button opens the whole-job diff in the same viewer.
  - Polling: re-render the detail only when the open job's `updated` changes. Remember which toggles are open (by a key such as `run.id + ':prompt'`), restore them, and keep the panel's scroll position.
  - Toggles are buttons with `aria-expanded`. Enter or Space toggles, and the focus ring is visible.

- [ ] **Step 1: Write the failing view tests:**

```bash
test_fold() {
  local g='[{"kind":"spec"},{"kind":"round","round":1},{"kind":"between","after":1},{"kind":"round","round":2},{"kind":"between","after":2},{"kind":"round","round":3},{"kind":"approve"}]'
  assert_eq '["spec","round","fold","between","round","approve"]' "$(v "foldTimeline($g).map(x=>x.kind)")" "three rounds fold the middle"
  assert_eq '"Rework cycle 1 (round 2)"' "$(v "foldTimeline($g)[2].label")" "singular label"
}
test_parse_diff() {
  local d; d=$(printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n ctx\n+<b>new</b>\n' | jq -Rs .)
  assert_eq '["x",1,0]' "$(v "(p=>[p.path,p.added,p.removed])(parseDiff($d)[0])")" "one file, one added line"
}
```

- [ ] **Step 2: Run them.** Expect FAIL.
- [ ] **Step 3: Implement** the timeline, toggles and diff viewer. Diff line text goes through `escapeHtml`.
- [ ] **Step 4: Run `factory/test/run`.** Expect all pass.
- [ ] **Step 5: Commit** `dashboard: runs timeline with prompts, outputs and task diffs`.

### Task 8: Acceptance on real data (orchestrator, not the builder)

Done by the reviewing session, not handed to the builder. It needs the user's other repo, a browser and judgment.

- [ ] Run `factory/test/run` and confirm `all test files passed`.
- [ ] In `~/Development/garmin-ai-coach`, while `origin/factory/00x-…` still exists, run `git update-ref refs/factory/jobs/001-event-bus-tenant-boundary origin/factory/001-event-bus-tenant-boundary`, and the same for `002-eval-gate-blocking`.
- [ ] Make a test factory: copy this branch's `factory/` into a scratch clone of garmin-ai-coach (so the repo and its refs are real), with both job folders. Start `factory/bin/dashboard --port <free>`. Check:
  - 001 and 002 are in Done.
  - 001's detail shows 7 criteria with covering tasks.
  - Rounds 2 to 7 are folded.
  - Codex runs have prompts.
  - Task 903.1's Changes shows commit `07efd776`'s diff.
- [ ] Spec acceptance 4 and 4a: run `prompt-record` and `run-adversarial` (with the stub companion) into a job, and the detail shows both prompts. Bookmark a test merge, delete its branch, and confirm task diffs still show.
- [ ] Browser (Playwright): light theme, dark theme, keyboard only (Tab to a card, Enter, toggles with Space, Escape), and a 390px-wide window. Take screenshots of each, and check contrast.
- [ ] Run the antislop Delivery Gate and report it, with no FAIL.
