# Jev Decisions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let TypeSafe's Jev make three fast multiple-choice calls in the factory loop: route each build task to a model tier, triage Notes from an all-PASS round, and skip reviewers with nothing to review. Each call has a confidence floor and a fallback to today's behaviour.

**Architecture:** `factory/bin/jev` is the only thing that talks to TypeSafe. It redacts the state, sends one request, validates the answers and prints JSON. `factory/bin/jev-decide route|triage|reviewers` builds each decision's plain-English state from job files, applies guardrails, the confidence floor and the Sol cap, writes `jev.jsonl` and any result files, and prints one line. The orchestrator (SKILL.md) acts on that line. Question wording lives in `factory/jev/<decision>.json`.

**Tech Stack:** bash + `jq` + `curl` (like the rest of `factory/bin/`), shell tests under `factory/test/` using `lib.sh`, and node for the dashboard view tests.

**Spec:** `docs/superpowers/specs/2026-10-24-jev-decisions-design.md`

## Global Constraints

- Endpoint `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer $JEV_KEY`, body `{"model", "state", "questions"}`. Each question is `{"type": "choice", "criteria": {<option>: <what> | {"what", "not_for"}}, "instructions": {"question", "about", "judge_by"}}` (`JevBrain.body`).
- 1.5 s deadline. One retry after 300 ms on 429, 5xx or a dropped connection (HTTP `000`), only if the deadline allows.
- A missing question, or a choice the question didn't offer, fails the whole call. On failure, log only the HTTP status, never the body.
- Never send code, diffs, logs, command output or environment files. Redact keys, tokens, email addresses and URLs with credentials to `[redacted]`. Keep the state under about 3k tokens (cap: 12000 characters).
- `factory/settings.json` `jev` defaults: `{"send": "off", "route": true, "triage": true, "reviewers": true, "min_confidence": 0.7, "sol_ceiling": 0.8, "park_paths": [], "model": "jev-latest"}`. `send` is `off` | `metadata` | `summary`. With `off`, Jev is never called.
- Models are named only in `models.json`. Route options are the tiers `light` → `builder-light`, `standard` → `builder-standard`, `thorough` → `builder`, `strong` → `builder-escalation`.
- An answer is used only when its chosen option's probability is ≥ `min_confidence`.
- `strong` is used only while the newest Codex rollout's `rate_limits.primary.used_percent` < `sol_ceiling × 100`. With no rollout, `strong` is allowed. The check is skipped when `builder-escalation`'s provider isn't `openai`.
- Fallback reasons in `jev.jsonl` are exactly `low-confidence`, `cap`, `guardrail` and `error`.
- Never triaged (they go to the approver): every `reviewer-security` Note, and any Note whose path matches a park glob.
- `reviewer-adversarial` always runs. `security` and `code` always run in a run's first round (`N - round_base == 1`).
- Skipped review file: `VERDICT: SKIPPED`, a blank line, then `Skipped by Jev (p=<p>): <the state line that decided it>.`
- Jev's own tokens go only in `jev.jsonl`, never in `usage.jsonl`.
- Every `jev` failure, a missing key or a bad config falls back to today's behaviour. `jev-decide` always exits 0.

## Review Focus

1. **Root-level guarded files.** Notes on a root `.env`, `package.json` or `Dockerfile` must match `**/.env*`, `**/package.json` and `**/Dockerfile*`, even with no directory in front. Pinned in Task 4 (`test_park_root_files`).
2. **Adversarial Notes.** `run-adversarial` appends `Suggested next steps:` and bullets inside `## Notes`, and other lenses write `None.` or free lines with no bullet. Neither the steps nor `None.` is a Note. Pinned in Task 4 (`test_note_parsing`).
3. **Secrets in summary mode.** A key or email inside a task description or Note must reach neither TypeSafe nor `jev.jsonl`. The log stores the redacted state `jev` returns. Pinned in Task 1 (`test_redacts_state`) and Task 3 (`test_route_logs_redacted_state`).
4. **Slow server.** A slow server must never stall a job. `--max-time` never exceeds the time left, and the retry is skipped when the first try used up the budget. Pinned in Task 1 (`test_no_retry_past_deadline`).
5. **Repos with no Jev setup.** A hand-edited `models.json` without the tier keys, or `send` on with no `JEV_KEY`, falls back to `builder` with one stderr line and no failure. Pinned in Task 3 (`test_route_missing_tier_key`, `test_route_no_key`).

---

### Task 1: `factory/bin/jev`, the TypeSafe client

**Files:**
- Create: `factory/bin/jev`
- Modify: `factory/settings.example.json` (add the `jev` block with the defaults above)
- Test: `factory/test/jev.test.sh`

**Interfaces:**
- Produces: `factory/bin/jev <questions-file> <state-file>`.
  - `<questions-file>` is the request's `questions` object.
  - Reads `JEV_KEY`, plus `send` and `model` from `factory/bin/settings jev` (merged over the defaults).
  - Exit 0 prints one compact JSON line: `{"model": <response model>, "state": <redacted state sent>, "answers": {<key>: {"choice": <name>, "p": <probabilities[choice], or 1 if absent>, "probabilities": {...}}}, "latency_ms": <int>, "input_tokens": <int|null>}`.
  - Exit 1: the call failed. One stderr line: `jev: HTTP <status>`, `jev: can't reach the server`, `jev: no answers` or `jev: no usable answer for <key>`.
  - Exit 2: usage or config error (missing file, no `JEV_KEY`, or `questions` isn't a non-empty object).
  - Exit 3: `send` is `off` (stderr `jev: off`).
  - `JEV_URL` overrides the endpoint for tests.

- [ ] **Step 1: Write the failing tests.** The fake curl below pins the curl interface that `jev` must use:
  - `curl -sS -o <body-file> -w '%{http_code} %{time_total}' --max-time <seconds> -H @<header-file> -H 'Content-Type: application/json' --data-binary @<request-file> <url>`
  - The key is only in `<header-file>` (mode 600, removed afterwards), never in argv.

```bash
#!/usr/bin/env bash
# Tests for factory/bin/jev.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# respond <n> <code> <time> <body>: the fake curl's answer to its n-th call.
respond() { printf '%s %s\n%s' "$2" "$3" "$4" >"$TEST_TMP/curl.$1"; }
ON='{"jev":{"send":"summary"}}'
setup() { # [settings-json]
  local settings=${1:-$ON}
  R=$(mkrepo); rm -f "$TEST_TMP"/curl.* "$TEST_TMP"/req.* "$TEST_TMP"/hdr.* "$TEST_TMP"/max.* "$STUBS/curl.calls"
  printf '%s' "$settings" >"$R/factory/settings.json"
  printf '{"tone":{"type":"choice","criteria":{"a":"A","b":{"what":"B","not_for":"x"}},"instructions":{"question":"q","about":"s","judge_by":"j"}}}' >"$TEST_TMP/q.json"
  printf 'Task: rename foo.\n' >"$TEST_TMP/s.txt"
  export JEV_KEY=sk-test-123456789
  # shellcheck disable=SC2016
  stub curl '
n=$(( $(cat "$TEST_TMP/curl.n" 2>/dev/null || echo 0) + 1 )); echo $n >"$TEST_TMP/curl.n"
while [ $# -gt 0 ]; do case $1 in
  -o) out=$2; shift ;; -H) case $2 in @*) cp "${2#@}" "$TEST_TMP/hdr.$n" ;; esac; shift ;;
  --data-binary) cp "${2#@}" "$TEST_TMP/req.$n"; shift ;; --max-time) echo "$2" >"$TEST_TMP/max.$n"; shift ;;
esac; shift; done
r="$TEST_TMP/curl.$n"; [ -f "$r" ] || r="$TEST_TMP/curl.1"
tail -n +2 "$r" >"$out"; head -n 1 "$r" | tr -d "\n"
case $(head -c 3 "$r") in 000) exit 7 ;; esac; exit 0'
  rm -f "$TEST_TMP/curl.n"
}
J() { "$R/factory/bin/jev" "$TEST_TMP/q.json" "$TEST_TMP/s.txt"; }
OK='{"model":"jev-2","answers":{"tone":{"type":"choice","choice":"b","confidence":0.7,"probabilities":{"a":0.2,"b":0.8}}},"usage":{"input_tokens":120,"output_tokens":3}}'
```

Tests (each one calls `setup`, then `J`):
- `test_ok`: `respond 1 200 0.2 "$OK"`. Assert:
  - exit 0;
  - `.answers.tone.choice == "b"`, `.answers.tone.p == 0.8`, `.model == "jev-2"` and `.input_tokens == 120`;
  - `req.1` has `.model == "jev-latest"`, `.state == "Task: rename foo.\n"`, and `.questions` equal to `q.json`;
  - `hdr.1` contains `Authorization: Bearer sk-test-123456789`;
  - `curl.calls` doesn't contain `sk-test`.
- `test_off`: default settings (`setup '{}'`). Exit 3, and `curl.calls` doesn't exist.
- `test_no_key`: `unset JEV_KEY`. Exit 2, and no curl call.
- `test_retry_once_on_429`: responses 429 then 200 (`$OK`). Exit 0, and `curl.n == 2`.
- `test_retry_on_dropped_connection`: response `000` then 200. Exit 0.
- `test_no_retry_past_deadline`: `respond 1 503 1.4 ''`. Assert exit 1, stderr exactly `jev: HTTP 503`, and `curl.n == 1`. Also assert `max.1` ≤ 1.5.
- `test_second_try_gets_time_left`: 429 at time 0.5, then 200. `max.2` is ≤ 0.7 and > 0.
- `test_error_body_not_logged`: `respond 1 500 0.1 '{"secret":"leak"}'` twice. Stderr doesn't contain `leak`.
- `test_bad_choice`: an answer with `"choice":"zzz"`. Exit 1, stderr `jev: no usable answer for tone`.
- `test_missing_question`: `{"answers":{}}`. Exit 1, stderr `jev: no usable answer for tone`.
- `test_no_probabilities`: an answer with no `probabilities`. `.answers.tone.p == 1`.
- `test_redacts_state`: the state holds all of these, and each comes out as `[redacted]` in both `req.1 .state` and the printed `.state`:
  - `sk-proj-abcdefghijklmnop`
  - `ghp_abcdefghijklmnopqrstuvwxyz0123`
  - `AKIAABCDEFGHIJKLMNOP`
  - `Bearer abc.def.ghi`
  - `me@example.com`
  - `https://bob:hunter2@host/x`
  - `token=abcd1234efgh5678`

  Plain words and the path `src/api/key-handler.ts` survive.
- `test_state_capped`: a 20000-character state. `req.1 .state` has length ≤ 12000.

- [ ] **Step 2: Run the tests to make sure they fail.** Run `bash factory/test/jev.test.sh`. Expected: FAIL (no `factory/bin/jev`).

- [ ] **Step 3: Implement `factory/bin/jev`.**
  - Use the header comment and usage block style of `run-codex`.
  - Do the redaction in `jq` with `gsub` (patterns are your choice, within the test above). Build the request with `jq -n --arg model --rawfile state --slurpfile q`.
  - Elapsed time is the sum of curl's `time_total`, compared with `awk`. `--max-time` is the time left, rounded down to 0.01 s.
  - Validate the answers against `q.json`'s keys and each key's `criteria` keys.
  - Add the `jev` block to `settings.example.json` with exactly the defaults from Global Constraints.

- [ ] **Step 4: Run the tests to make sure they pass.** Run `bash factory/test/jev.test.sh && shellcheck factory/bin/jev`. Expected: `N passed, 0 failed`, and no shellcheck output.

- [ ] **Step 5: Commit.**
```bash
git add factory/bin/jev factory/test/jev.test.sh factory/settings.example.json
git commit -m "jev: TypeSafe client with deadline, retry, redaction and answer checks"
```

### Task 2: Tier roles in every preset

**Files:**
- Modify: `factory/presets/{mixed,lean,claude,openai}.json` and `factory/models.json` (which stays a copy of `mixed`)
- Modify: `factory/bin/models` header comment (mention the tier keys)
- Test: `factory/test/models.test.sh`

**Interfaces:**
- Produces: the role keys `builder-light` and `builder-standard`, each with `"agent": "builder"`. `run-codex`, `usage-record` and the factory-agent prompt then all use `builder.md`.

| Preset | `builder-light` | `builder-standard` |
|---|---|---|
| `mixed`, `openai` | `{"provider":"openai","model":"gpt-6-luna","effort":"medium","network":true,"agent":"builder"}` | same, with `"effort":"high"` |
| `lean` | Luna `medium` (as above) | Luna `high` (as above) |
| `claude` | `{"provider":"anthropic","model":"sonnet","agent":"builder"}` | same |

- [ ] **Step 1: Write the failing test.** Add `test_builder_tiers`. For each preset, assert:
  - `jq -r '[."builder-light".agent, ."builder-standard".agent] | join(" ")'` is `builder builder`;
  - for `mixed`, `jq -r '[."builder-light".effort, ."builder-standard".effort] | join(" ")'` is `medium high`.

  `test_presets_cover_same_roles` and `test_shipped_models_is_mixed` already pin that the presets match.
- [ ] **Step 2: Run the test to make sure it fails.** Run `bash factory/test/models.test.sh`. Expected: FAIL on `test_builder_tiers`.
- [ ] **Step 3: Add the two keys** to all four presets and `models.json`, right after `builder`.
- [ ] **Step 4: Run the tests to make sure they pass.** Run `bash factory/test/models.test.sh && bash factory/test/run-codex.test.sh`. Expected: all pass.
- [ ] **Step 5: Commit.** `git commit -m "models: builder-light and builder-standard tiers in every preset"`

### Task 3: `jev-decide route`

**Files:**
- Create: `factory/bin/jev-decide`, `factory/jev/route.json`
- Test: `factory/test/jev-decide.test.sh`

**Interfaces:**
- Consumes: `factory/bin/jev` (Task 1), called as `${JEV_BIN:-$factory/bin/jev}` so tests can swap it out. Also the tier keys (Task 2).
- Produces:
  - `factory/bin/jev-decide route <job-folder> <task-id>` prints one line, `<role-key> (<why>)`. `<why>` is one of:
    - `jev <option> p=<p>`
    - `fallback low-confidence|cap|error`
    - `off`

    It always exits 0, and the orchestrator takes the first word.
  - Shared helpers inside `jev-decide`, used by Tasks 4 and 5:
    - `cfg`: `settings jev` merged over the defaults, as JSON.
    - `ask <decision> <questions-file> <state-file>`: prints `jev`'s JSON or fails.
    - `log_line <job> <json>`: appends one compact line to `<job>/jev.jsonl`.
  - Every `jev.jsonl` line looks like this:

    ```json
    {"ts": "...", "decision": "route|triage|reviewers", "task": "...", "round": "...",
     "send": "metadata|summary", "state": "<redacted state, or null when nothing was sent>",
     "answers": {"<key>": {"choice": "...", "p": 0.0}},
     "latency_ms": null, "input_tokens": null,
     "outcome": {"<key>": {"used": true, "why": null, "did": "<what the factory does>"}}}
    ```

    `why` is null, or one of `low-confidence`, `cap`, `guardrail`, `error`.
  - `route.json` holds one question, `route`, with the four options and the spec's "Means" text as each `what`. `strong`'s `not_for` is `"a task that is merely long but straightforward"`.

**Route state, one fact per line:**
- in `summary` mode only, the task's title (metadata mode has no title or description);
- its label (`fix`/`final`/none, from `job.json` `.fix` and `.final`);
- the job's round;
- the files the task names, with line counts (`wc -l` in the worktree; `new` when missing).

  Files come from paths in the `plan.json` description, matched by title. For a fix task titled `Fix round <N> <lens> review`, they come from the paths in that review's `## Findings`. For `Fix round <N> notes`, they come from `round-<N>/triage.json` `.fix_now[].path`.
- In `summary` mode only, the description;
- a history line for the task's top-level directories. It covers every task in every `factory/jobs/*/job.json` whose `build/<id>.md` `## Commit` Files touch one of them: count, and per role (`.role // "builder"`) how many ran and how many went BLOCKED (`runs > 1` or `status == "blocked"`).

  The exact wording is the builder's choice.

**Behaviour:**
1. With `send` off or `route` false, print `builder (off)` and log nothing.
2. Otherwise, a `jev` failure prints `builder (fallback error)`, logs `why: error`, and copies `jev`'s stderr line to stderr once.
3. When the choice's p is below `min_confidence`: `builder`, `low-confidence`.
4. When the choice is `strong` and the cap is hit: `builder`, `cap`. The cap reads the newest `rollout-*.jsonl` by mtime under `${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}`: its last `rate_limits.primary.used_percent`. The check runs only when `models.json` `builder-escalation.provider == "openai"`.
5. A tier key missing from `models.json` maps to `builder` and stays `used: true`, with `did` saying so.

- [ ] **Step 1: Write the failing tests.**
  - Fixture: `mkrepo`, then a job folder with:
    - `job.json`: `{round: 1, round_base: 0, worktree: $R, tasks: [{id: "b.1", title: "Rename foo", status: "in_progress", runs: 1}]}`;
    - `plan.json`: a task titled `Rename foo` with the description `Scope: rename in src/foo.sh. Contact me@example.com.`;
    - `$R/src/foo.sh` with 3 lines.
  - Fake jev: `stub fakejev 'cp "$1" "$TEST_TMP/questions.sent"; cat "$2" >"$TEST_TMP/state.sent"; cat "$TEST_TMP/jev.out"; exit ${JEV_RC:-0}'`, with `JEV_BIN=$STUBS/fakejev`. Each test writes `jev.out` as `jev`'s JSON shape.
  - `test_route_off`: with no settings, the output is `builder (off)` and no `jev.jsonl` exists.
  - `test_route_light`: `light`, p 0.9, `send` summary. The output is `builder-light (jev light p=0.9)`, the log line has `.decision == "route"` and `.outcome.route.used == true`, and the state sent contains `src/foo.sh` and `Rename foo`.
  - `test_route_metadata_hides_description`: `send` metadata. The state sent contains `src/foo.sh` but neither `Scope:` nor `Rename foo`.
  - `test_route_low_confidence`: p 0.6. Output `builder (fallback low-confidence)`.
  - `test_route_cap`:
    - with `CODEX_SESSIONS_DIR` holding a rollout whose last `used_percent` is 85, `strong` p 0.9 gives `builder (fallback cap)`;
    - at 50, it gives `builder-escalation (jev strong p=0.9)`;
    - with an empty directory, `builder-escalation`.
  - `test_route_cap_skipped_for_claude`: after `factory/bin/models claude`, at 85% it is still `builder-escalation`.
  - `test_route_error`: `JEV_RC=1`. Output `builder (fallback error)`, and `.outcome.route.why == "error"`.
  - `test_route_no_key`: with the real `jev`, `send` summary and no `JEV_KEY`. Output `builder (fallback error)` and exit 0.
  - `test_route_missing_tier_key`: delete `builder-light` from `models.json`. A `light` p 0.9 answer gives `builder (jev light p=0.9)`.
  - `test_route_logs_redacted_state`: the fake jev prints a `.state` with `[redacted]`. `jev.jsonl` `.state` equals it, and the file doesn't contain `me@example.com`.
  - `test_route_history`: a second job folder with a closed task `a.1` (`role: "builder"`, `runs: 2`) whose `build/a.1.md` Files lists `src/bar.sh`. The state sent mentions `src/` and one BLOCKED.
- [ ] **Step 2: Run the tests to make sure they fail.** Run `bash factory/test/jev-decide.test.sh`. Expected: FAIL (no script).
- [ ] **Step 3: Implement `factory/bin/jev-decide`** with `main` dispatching subcommands the way `usage-record` does, plus `factory/jev/route.json`.
- [ ] **Step 4: Run the tests to make sure they pass.** Run `bash factory/test/jev-decide.test.sh && shellcheck factory/bin/jev-decide`. Expected: all pass.
- [ ] **Step 5: Commit.** `git commit -m "jev: route each build task to a model tier"`

### Task 4: `jev-decide triage`

**Files:**
- Modify: `factory/bin/jev-decide`
- Create: `factory/jev/triage.json`, `factory/jev/park-paths.txt`
- Test: `factory/test/jev-decide.test.sh`

**Interfaces:**
- Consumes: `cfg`, `ask` and `log_line` (Task 3).
- Produces: `factory/bin/jev-decide triage <job-folder> <N>`. It writes `round-<N>/triage.json` and `round-<N>/triage.md`, then prints `triage round <N>: <a> fix-now, <b> follow-up, <c> fine, <d> for the approver`. With `send` off or `triage` false, it writes nothing and prints `triage round <N>: off`.
  - `triage.json` holds four lists, `{"fix_now": [], "follow_up": [], "fine": [], "approver": []}`. Each item is `{"n", "lens", "path", "title", "text", "p", "why"}`:
    - `path` is null when the Note names none;
    - `title` is the adversarial `<title>`, or else the Note's first sentence cut to 80 characters;
    - `why` is set only on `approver` items: `guardrail`, `low-confidence`, `error` or `jev` (Jev chose `approver` in metadata mode).
  - `triage.md` starts with `TRIAGE: <a> fix-now, <b> follow-up, <c> fine, <d> approver`, then has `## Fix now`, `## Follow-up`, `## Fine` and `## For the approver` sections. Each section holds `- [<lens>] <text> (p=<p>)` items (approver items carry `— <why>`), or `None.`.
  - `triage.json` (the question file) holds the template questions `note` (`fix-now`/`follow-up`/`fine`, with the spec's "Means" as `what`) and `note-metadata` (`fine`/`approver`). The script expands the right one into `note.1` … `note.<k>`. Each copy's `instructions.about` reads `Note <n> in the state`.
  - `park-paths.txt` holds one glob per line, with exactly the spec's defaults: `**/.env*`, `**/*secret*`, `**/auth/**`, `**/migrations/**`, `.github/**`, `**/*.tf`, `infra/**`, `**/cdk*/**`, `**/Dockerfile*`, `**/package.json` and `**/*.lock`. `jev.park_paths` adds to them.

**Rules:**
- Notes are read from every `round-<N>/review-*.md`, in lens order security, code, ux, ui, adversarial.
- A Note is every non-blank line in `## Notes` up to the next `## ` heading or a line starting `Suggested next steps:`. Leading `- `, `* ` or `<n>. ` is stripped, and `None.` (or `None`) is skipped.
- A Note's path is its first token that looks like a path (it contains `/`, or ends in `.<ext>`, with any backticks and any `:<line>` stripped).
- A glob matches when bash `[[ $path == $glob ]]` matches either `$path` or `./$path`.
- Security Notes and park-path matches are not sent and go to the approver with `guardrail`.
- In metadata mode the state has lens, severity and confidence when the Note gives them, the path, and whether a Note in rounds 1…N-1 named the same path. Summary mode adds the text.
- When every Note is guarded, no call is made, and the log line has `state: null`.

- [ ] **Step 1: Write the failing tests.**
  - Fixture: a round folder with `review-security.md`, `review-code.md` and `review-adversarial.md`.
    - Security has a Note on `src/x.ts`.
    - Code has `## Notes` then `None.`.
    - Adversarial's Notes: `- src/api.ts:12 [medium, confidence 0.7] Off by one. ... Fix: ...`, `- package.json:3 [low, confidence 0.5] Pin it. ...` and `- docs/a.md:1 [low, confidence 0.4] Typo. ...`, then a blank line, `Suggested next steps:` and `- run tests`.
  - `test_note_parsing`: with summary mode and the fake jev answering every sent question `fine` p 0.9, `triage.json` has 4 Notes in total. None of them is `run tests` or `None.`.
  - `test_park_root_files`: the `package.json` Note lands in `approver` with `why == "guardrail"`. So do Notes on `.env` and `Dockerfile` (extra fixture lines). The security Note does too.
  - `test_guarded_not_sent`: the state sent doesn't contain `Pin it`, and the questions sent have exactly `note.1` and `note.2`.
  - `test_triage_outcomes`:
    - `note.1` `fix-now` p 0.8 and `note.2` `follow-up` p 0.75 give the line `triage round 1: 1 fix-now, 1 follow-up, 0 fine, 2 for the approver`;
    - `triage.md`'s first line is `TRIAGE: 1 fix-now, 1 follow-up, 0 fine, 2 approver`;
    - `.follow_up[0].title == "Typo"`.
  - `test_triage_low_confidence`: `note.1` p 0.5 goes to `approver` with `low-confidence`.
  - `test_triage_metadata`: `send` metadata. The questions sent use the `fine`/`approver` options, and the state doesn't contain `Off by one`. A `fix-now` can't happen: there's no such option, so a fake answer of `fix-now` is treated as an `error`.
  - `test_triage_park_extend`: `jev.park_paths: ["docs/**"]` sends the `docs/a.md` Note to the approver with `guardrail`.
  - `test_triage_error`: `JEV_RC=1`. Every sent Note goes to the approver with `error`, and the files are still written.
  - `test_triage_off`: prints `triage round 1: off` and writes no `triage.json`.
- [ ] **Step 2: Run the tests to make sure they fail.** Run `bash factory/test/jev-decide.test.sh`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement `cmd_triage`** and the two data files.
- [ ] **Step 4: Run the tests to make sure they pass.** Run `bash factory/test/jev-decide.test.sh && shellcheck factory/bin/jev-decide`. Expected: all pass.
- [ ] **Step 5: Commit.** `git commit -m "jev: triage Notes from an all-PASS round, guarded paths go to the approver"`

### Task 5: `jev-decide reviewers`

**Files:**
- Modify: `factory/bin/jev-decide`
- Create: `factory/jev/reviewers.json`
- Test: `factory/test/jev-decide.test.sh`

**Interfaces:**
- Consumes: `cfg`, `ask` and `log_line` (Task 3).
- Produces: `factory/bin/jev-decide reviewers <job-folder> <N>`.
  - For each skipped lens it writes `round-<N>/review-<lens>.md` with exactly: `VERDICT: SKIPPED`, a blank line, then `Skipped by Jev (p=<p>): <state line>.`
  - It prints `reviewers round <N>: run <lens, ...>; skip <lens> (p=<p>), ...`, or `reviewers round <N>: run all` when nothing is skipped or it is off.
  - `reviewers.json` holds the questions `review.ux`, `review.ui`, `review.security` and `review.code`, each with the options `run`/`skip`. `skip`'s `not_for` is `"a change that might alter what this reviewer checks"`.

**Rules:**
- The run index is `r = N - (.round_base // 0)`.
- `review.ux` and `review.ui` are always asked. `review.security` and `review.code` are asked only when `r ≥ 2`. Adversarial is never asked.
- The state comes from `git -C <worktree> diff --numstat <base>...HEAD`, with `<base>` from `factory/bin/settings base`.
  - It lists up to 40 files by lines changed, then `and <k> more`.
  - UI files are those ending in `.html .css .scss .sass .less .tsx .jsx .vue .svelte .astro .erb .hbs .swift .xib .storyboard`, or with a path containing `components/`, `pages/`, `views/`, `templates/` or `public/`.
  - There is one line per asked lens, starting `<lens>: `.
    - ux/ui: the UI file count and names.
    - security/code, from `r ≥ 2`: the lens's previous-round verdict, its Findings and Notes counts, and the files the previous round's fix tasks changed (their `build/<id>.md` Files, for `job.json` tasks whose title starts `Fix round <N-1> `).
  - That line is what the SKIPPED file quotes.
- The answer is used when p ≥ `min_confidence`. A `jev` error means every lens runs.
- A lens whose review file already exists is left alone: on resume, a skip isn't asked again.

- [ ] **Step 1: Write the failing tests.**
  - Fixture: `mkrepo` with a commit on the job branch changing `docs/a.md`, and `job.json` `round_base: 0`.
  - `test_reviewers_first_round`: with N=1 the questions sent are exactly `review.ui` and `review.ux`. Answering both `skip` p 0.9:
    - prints `reviewers round 1: run security, code, adversarial; skip ux (p=0.9), ui (p=0.9)`;
    - `round-1/review-ux.md` line 1 is `VERDICT: SKIPPED` and line 2 is blank;
    - line 3 starts `Skipped by Jev (p=0.9): ux: ` and ends with `.`.
  - `test_reviewers_round_two_asks_all`: with N=2 and a `round-1/` holding PASS files, the questions sent include `review.security` and `review.code`.
  - `test_reviewers_low_confidence_runs`: a p 0.6 skip runs the lens, and no file is written.
  - `test_reviewers_ui_file_line`: a change to `src/components/Button.tsx` puts `ui: 1 UI file` (or wording that includes the name) in the state.
  - `test_reviewers_existing_file_kept`: an existing `round-1/review-ux.md` isn't rewritten, and `review.ux` isn't asked.
  - `test_reviewers_error_runs_all`: `JEV_RC=1` prints `reviewers round 1: run all`.
  - `test_reviewers_many_files`: 60 changed files. The state lists 40 and says `and 20 more`.
- [ ] **Step 2: Run the tests to make sure they fail.** Run `bash factory/test/jev-decide.test.sh`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement `cmd_reviewers`** and `reviewers.json`.
- [ ] **Step 4: Run the tests to make sure they pass.** Run `bash factory/test/jev-decide.test.sh && shellcheck factory/bin/jev-decide`. Expected: all pass.
- [ ] **Step 5: Commit.** `git commit -m "jev: skip reviewers a change gives nothing to review"`

### Task 6: Dashboard shows `SKIPPED`

**Files:**
- Modify: `factory/bin/dashboard:67` (the `pastRounds` regex accepts `SKIPPED`)
- Modify: `factory/dashboard.html` (`reviewBoxes` gives the state `skipped`, word `skipped`, with a muted `.reviewer.skipped` style in both themes; `reviewRoundLine` counts skipped and adds `, <k> skipped` when k > 0; the first-line classifier treats `VERDICT: SKIPPED` as neutral)
- Test: `factory/test/dashboard.test.sh`, `factory/test/dashboard-view.test.sh`

- [ ] **Step 1: Write the failing tests.**
  - In `dashboard.test.sh`, extend the past-rounds fixture so `round-1/review-ux.md` is `VERDICT: SKIPPED`. Assert `.jobs[0].past[0].ux == "SKIPPED"`.
  - In `dashboard-view.test.sh`, add `test_skipped_chip`:
    - `reviewBoxes({ux:"SKIPPED"})` includes `reviewer skipped` and `>skipped<`;
    - `reviewRoundLine({stage:"review",round:1,reviews:{security:"PASS",ux:"SKIPPED"}})` includes `1 skipped`.
- [ ] **Step 2: Run the tests to make sure they fail.** Run `bash factory/test/dashboard.test.sh; bash factory/test/dashboard-view.test.sh`. Expected: the new assertions FAIL.
- [ ] **Step 3: Implement** the changes listed under Files.
- [ ] **Step 4: Run the tests to make sure they pass.** The same commands. Expected: all pass.
- [ ] **Step 5: Commit.** `git commit -m "dashboard: show skipped reviewers"`

### Task 7: `usage-summary` reports Jev

**Files:**
- Modify: `factory/bin/usage-summary` (header comment and program)
- Test: `factory/test/usage-summary.test.sh`

**Interfaces:**
- Consumes: the `jev.jsonl` line shape (Task 3) and `job.json` `tasks[].role`.
- Produces: up to three lines, printed after the trend line and before `quota:`, over every job folder with a `jev.jsonl`. A decision point with no lines prints nothing.
  - `jev route: <calls> calls, <used> used, fallbacks <list>; Sol <s>/<t> tasks; BLOCKED after route light <x>/<y>, standard <x>/<y>, thorough <x>/<y>, strong <x>/<y>`
  - `jev triage: <notes> notes, <used> used (fix-now <a>, follow-up <b>, fine <c>), fallbacks <list>`
  - `jev reviewers: <calls> calls, <skips> skips of <asked> asked, fallbacks <list>`

  How each count is made:
  - `<list>` is `<why> <k>` pairs in the order `low-confidence, cap, guardrail, error`, comma-separated, leaving out zeros. It is `none` when every count is zero.
  - Sol is tasks with `.role == "builder-escalation"` over tasks with `runs ≥ 1`, in those jobs.
  - "BLOCKED after route" pairs each used route line's option with its task in `job.json`. BLOCKED means `runs > 1` or `status == "blocked"`, over routed tasks with that option.

- [ ] **Step 1: Write the failing test.** Add `test_jev_lines`, with a job folder holding a `jev.jsonl`:
  - two used route lines (`light` for `t1`, `strong` for `t2`) and a `cap` fallback for `t3`, where `t2` has `runs: 2`;
  - a triage line with one `fix-now` used and one `guardrail`;
  - a reviewers line with one skip of two asked.

  Assert these lines exactly:
  - `jev route: 3 calls, 2 used, fallbacks cap 1; Sol 1/3 tasks; BLOCKED after route light 0/1, standard 0/0, thorough 0/0, strong 1/1`
  - `jev triage: 2 notes, 1 used (fix-now 1, follow-up 0, fine 0), fallbacks guardrail 1`
  - `jev reviewers: 1 calls, 1 skips of 2 asked, fallbacks none`

  Also assert that, with no `jev.jsonl`, the output has no `jev` line. The existing tests stay green.
- [ ] **Step 2: Run the test to make sure it fails.** Run `bash factory/test/usage-summary.test.sh`. Expected: FAIL.
- [ ] **Step 3: Implement it.** Add the `jev.jsonl` files to `inputs` and group them as the program already groups `usage.jsonl`.
- [ ] **Step 4: Run the tests to make sure they pass.** Run `bash factory/test/usage-summary.test.sh`. Expected: all pass.
- [ ] **Step 5: Commit.** `git commit -m "usage-summary: Jev calls, use and fallbacks per decision"`

### Task 8: Wire it into the loop and the roles

**Files:**
- Modify: `.claude/skills/factory/SKILL.md`
- Modify: `factory/agents/approver.md`, `autopilot.md`, `briefer.md`, `retro.md`, and `reviewer-{security,code,ux,ui,adversarial}.md`
- Modify: `README.md` and `INSTALL.md`
- Test: `factory/test/prose.test.sh`, plus `test_retro_role`'s cause list

**SKILL.md changes:**
- **Loop table.** The build row reads `builder` / `builder-light` / `builder-standard` / `builder-escalation`.
- **Files.** Add these lines:
  - `factory/jev/<decision>.json`: Jev's questions;
  - `<job>/jev.jsonl`: every Jev call;
  - `<job>/round-<N>/triage.{md,json}`.
- **job.json.** Tasks gain `role` (the role key that last built them) and `fix: true` on fix tasks. `reviews` values may be `SKIPPED`.
- **New `### Jev` section, under Running a role.**
  - Jev answers three quick choices through `factory/bin/jev-decide`, configured by `jev` in `factory/settings.json` (off unless `send` is `metadata` or `summary`).
  - Its line is the only output you read.
  - You never call `factory/bin/jev` yourself, never send Jev anything, and never override a `jev-decide` result with your own judgement.
- **Build step 2.** When today's rule picks `builder-escalation` (a second run, or a fix task in the run's last round), use it and don't route. Otherwise run `factory/bin/jev-decide route <job folder> <task-id>` and use the first word of its line as the role key. Record it as the task's `role`, with `model` from that key's `models.json` entry. Include the line's parenthesis in the report line.
- **Review round N step 2.** Run `factory/bin/jev-decide reviewers <job folder> <N>` first. Write `SKIPPED` to `job.json` for each lens it skipped, then run the rest in one message.
- **Review round N step 3.** A valid first line is also `VERDICT: SKIPPED`.
- **Review round N step 5.**
  - All PASS (`SKIPPED` counts as PASS here) with at least one Note line across the reviews, and `N - round_base < MAX_ROUNDS`: go to **Triage**.
  - Otherwise, all PASS: **Approve**.
- **New `### Triage` section.**
  - Run `factory/bin/jev-decide triage <job folder> <N>`.
  - For each `.follow_up[]` in `round-<N>/triage.json`, file a bead unless an open bead already has its title (the dedupe query in **/factory review** step 3): `bd create "<title>" --type=feature -p 2 -l factory,queued --deps discovered-from:<bead> -d "<text>\n\nFrom round <N> review Notes of factory/<job-id>." --silent`.
  - With `.fix_now` non-empty: file `Fix round N notes` (`-l factory,fix`, `-d "Address every Note under ## Fix now in factory/jobs/<job-id>/round-<N>/triage.md."`) and the usual `Verify all acceptance criteria (round N+1)` final task depending on it, exactly as a CHANGES round does. Then go to **Build**. This counts as a round, and skips the approver and autopilot.
  - Otherwise go to **Approve**.
- **Autopilot decision step 4 MERGE** and **/factory approve.** "every review `PASS`" becomes "every review `PASS` or `SKIPPED`".
- **/factory resume, review.** A `SKIPPED` file is a valid first line. With all reviews in and a `triage.md` present, continue from **Triage**'s filing (which dedupes by title).

**Role changes:**
- **`approver.md`.** In Read, add `round-<N>/triage.md` when present. "All five reviews ... `VERDICT: PASS`" becomes "every review in the final round is `VERDICT: PASS` or `VERDICT: SKIPPED` (not reviewed this round, not a reason to escalate)". Notes listed in `triage.md` under Fine or Follow-up are settled and aren't a reason to escalate by themselves. Judge the others as before.
- **`autopilot.md` and `briefer.md`.** The same two rules, where they talk about final-round reviews and APPROVE.
- **Each reviewer file.** From round 2 on, "your own `round-<N-1>/review-<lens>.md`" gains: "if it reads `VERDICT: SKIPPED`, use your latest review that doesn't".
- **`retro.md`.**
  - Add `jev.jsonl` to Read, whole.
  - Add a cause, `jev`: a Jev decision that cost an attempt. That covers a routed task that went BLOCKED, a `fix-now` Note whose fix task's `## Findings addressed` changed nothing, a Fine or Follow-up Note the approver escalated on, and a skipped lens whose next round found something.
  - Its fix is a `factory` edit to `factory/jev/<decision>.json`.
  - `## Cost` gains the job's share of the weekly cap: the first `quota.before` to the last `quota.after` over the job's codex rows.
- **`README.md`.** List `bin/jev`, `bin/jev-decide` and `factory/jev/`.
- **`INSTALL.md`.** Document the `jev` settings, `JEV_KEY`, `summary` for personal repos versus `metadata` elsewhere, and the note to check TypeSafe's terms before using `summary` on anything sensitive.

- [ ] **Step 1: Write the failing prose tests.** Add `test_jev_wiring` to `prose.test.sh`, using the existing `section` helper and `tr '\n' ' ' | tr -s ' '`.
  - SKILL.md contains:
    - `factory/bin/jev-decide route <job folder> <task-id>`
    - `factory/bin/jev-decide reviewers <job folder> <N>`
    - `factory/bin/jev-decide triage <job folder> <N>`
    - `### Triage`
    - `Fix round N notes`
    - `discovered-from:<bead>`
    - `` `PASS` or `SKIPPED` ``
  - The Jev section says `never override`.
  - `approver.md` contains `triage.md` and `VERDICT: SKIPPED`.
  - `autopilot.md` and `briefer.md` contain `SKIPPED`.
  - Each `reviewer-*.md` contains `VERDICT: SKIPPED`.
  - `retro.md` contains `jev.jsonl`.
  - INSTALL contains `JEV_KEY`, and README contains `bin/jev-decide`.
  - Update `test_retro_role`'s cause-list string to include `` `jev` ``, in whatever position you put it in `retro.md`.
- [ ] **Step 2: Run the tests to make sure they fail.** Run `bash factory/test/prose.test.sh`. Expected: FAIL on `test_jev_wiring` and `test_retro_role`.
- [ ] **Step 3: Make the prose edits** listed above, matching each file's voice: short, imperative, backticked names.
- [ ] **Step 4: Run the whole suite.** Run `factory/test/run`. Expected: `all test files passed`.
- [ ] **Step 5: Commit.** `git commit -m "factory: run Jev's route, reviewers and triage decisions in the loop"`
