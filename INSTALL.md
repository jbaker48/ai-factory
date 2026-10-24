# Install the factory into a project

Instructions for a coding agent installing this factory into a target repo.
`<source>` is the folder holding this file; `<target>` is the target repo's
root (`git rev-parse --show-toplevel` there). If the user hasn't said which
repo is the target, ask.

Work through the steps in order. Each ends on a **Done when**; finish it
before starting the next. The user decides anything that changes how the
factory behaves (the autopilot policy, models, commits); present those and
wait for an answer.

## 1. Check the tools

Run each check and note what is missing:

| Tool | Check | Needed for |
| --- | --- | --- |
| Beads | `bd --version` | everything |
| Codex CLI | `codex --version`, `codex login status` | every OpenAI role (the `mixed` and `openai` presets) |
| Codex plugin | `ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs` | `reviewer-adversarial` in the `mixed` preset |
| jq, node | `jq --version`, `node --version` | the scripts in `factory/bin/` |
| Claude Code | `claude --version`, 2.1.259 or later | `factory/bin/autopilot` (`--permission-prompts`) |
| agent-browser | `command -v agent-browser` | the UX and UI reviewers, if the project has pages |

Installing a missing tool changes the user's machine: list what is missing,
with each tool's install link from `<source>/README.md`, and let the user
install it.

**Done when** every tool printed a version, or the user knows which are
missing and has chosen to go on without them.

## 2. Check the target

In `<target>`:

- `git status --porcelain` prints nothing. Uncommitted work belongs to the
  user: ask them to commit or stash it.
- The default branch is `main`. The factory lands jobs into `main` by name
  and diffs against the base ref from `factory/settings.json` (`origin/main`
  or `main`). If the default is something else, tell the user before going on.
- Look for an earlier install: `.claude/skills/factory/`,
  `.claude/agents/factory-agent.md`, `factory/`. If one exists, this is an
  upgrade: show the user `diff -r` against `<source>` for each and get their
  go-ahead before overwriting. Their `factory/models.json` and
  `factory/autopilot-policy.md` are likely customised: the install script in
  step 3 keeps them, so if the user wants the source's copy instead, copy it
  over after step 3. A repo with a customised `autopilot-policy.md` should make
  the same change: MERGE needs every final-round review `PASS` or `SKIPPED`,
  not "all-PASS".

**Done when** the tree is clean, the user knows about any non-`main` default,
and any earlier install has the user's decision.

## 3. Copy the files

```bash
<source>/factory/bin/install <target>
```

The script reads `<source>/factory/manifest`, which lists the files it copies.
It copies the shipped files (the skill, the agent, the roles, the scripts, the
dashboard, the Jev templates, the presets) over the target's copies, and
writes the files the user owns (`factory/models.json`,
`factory/autopilot-policy.md`, `factory/jobs/.gitkeep`) only when the target
has none, so an upgrade keeps the user's copies; it never touches
`factory/settings.json`, which step 6 writes. It adds the factory's `.gitignore` lines the target lacks
(`/factory/jobs/*`, `!/factory/jobs/.gitkeep`, `/factory/imports/`,
`/factory/autopilot-runs/`), each once, and writes `factory/VERSION`: the
source commit SHA. It leaves everything else in the target's `.claude/` as it
is. It copies `factory/AGENTS.template.md` too: step 5 and `/factory setup`
write `AGENTS.md` from it, and no job reads it.

**Done when** `ls <target>/factory/bin` lists `run-codex`, `run-adversarial`,
`job-set` and `autopilot`, all executable, and `git -C <target> status`
shows no file under `factory/jobs/` other than `.gitkeep`.

## 4. Beads

Steps 4 and 5 are what `/factory setup` does: in a Claude Code session in
`<target>` you can run it instead, and it ends each step on the same **Done
when**. Running it again later updates the factory's sections of `AGENTS.md`
and keeps the user's.

- **No `.beads/` in the target**: run `bd init` there. It also writes its own
  integration files (an `AGENTS.md` section, a `CLAUDE.md`, editor rules, a
  Beads skill); note each file it creates or changes for step 5.
- **`.beads/` exists**: keep it. People and other tools share it. Tell the
  user the brownfield path: `/factory import <prd>` maps a PRD onto the
  existing beads before any job runs (see **Brownfield** in
  `<source>/README.md`).

**Done when** `bd --readonly ready` runs in the target without an error.

## 5. AGENTS.md

Every factory role reads the target's `AGENTS.md` first, and the role files
carry nothing repo-specific, so this step decides whether jobs work at all.
Start from `<target>/factory/AGENTS.template.md`. Its header comment lists the
conditions the commands run under; read it before writing anything.

1. **Gather the facts from the repo**: package manager and lockfile, toolchain
   pins (`.nvmrc`, `.tool-versions`, `pyproject.toml`), scripts in
   `package.json` or the `Makefile`, the CI workflow (its steps are usually the
   truest validation commands), `.env.example`, `docker-compose.yml`, and the
   docs folder, including a glossary and an ADR folder for the template's
   `## Domain docs` section. Keep the user's existing `AGENTS.md` or `CLAUDE.md` content:
   merge it into the template's sections.
2. **Write `AGENTS.md`**, filling every `<...>`, keeping the template's
   `factory:begin` and `factory:end` markers, and deleting its header comment.
   Content no template section covers goes outside the markers. Then make `CLAUDE.md` the one line `@AGENTS.md`; if
   `CLAUDE.md` has content of its own, merge it into `AGENTS.md` first.
3. **Scope Beads' own section to people.** If `bd init` added instructions
   telling agents to claim, close, commit or push, mark that section as being
   for people working by hand, and add that factory agents read Beads only
   (`bd --readonly`) and leave commits and Beads writes to the orchestrator.
4. **Prove the commands in a fresh worktree**, the way the factory will run
   them:
   ```bash
   git -C <target> worktree add -q --detach <target>/../factory-install-check HEAD
   ```
   Copy in the uncommitted `AGENTS.md` if you need it there, then in that
   worktree run the setup, every validation command (whole-repo and scoped
   forms), and the dev server on port `5199` with its readiness check. Stop
   the server, then `git -C <target> worktree remove --force <target>/../factory-install-check`.
   A command that fails here fails in every job: fix the command or the
   setup in `AGENTS.md`, and rerun until it passes.

**Done when** `AGENTS.md` has no `<...>` left, every command in it passed in
the fresh worktree (or the user has accepted a named failure), and the dev
server bound exactly port `5199`.

## 6. Decisions for the user

Show the user each of these and record their answer:

- **`factory/autopilot-policy.md`**: what the autopilot may merge without a
  person. Point out the project's own sensitive areas (from `AGENTS.md`) that
  the policy doesn't yet name, and offer to add them.
- **`factory/models.json`**: the model and effort per role. Ask which
  subscriptions they have and run the matching preset: both,
  `factory/bin/models mixed` (the default); Claude only,
  `factory/bin/models claude` (no Codex CLI or plugin); ChatGPT only,
  `factory/bin/models openai` (no Codex plugin, but the orchestrator is still
  Claude Code). For `mixed` and `openai`, confirm their Codex account can use
  the OpenAI models listed.
- **`factory/settings.json`**: write it from `factory/settings.example.json`.
  Ask whether the repo has a GitHub remote: yes sets `"land": "pr"`, no sets
  `"land": "local"`. Ask which labels mark high-priority beads and put them in
  `priority_labels` (`[]` for none), and leave `jobs` at 1 unless they want
  parallel jobs: `jobs` is how many jobs `factory/bin/autopilot` runs at once
  (`--jobs N` overrides it per run). `factory_source` is optional: the
  absolute path of a local ai-factory checkout (`<source>` works if it is
  one), where retros open PRs with factory fixes; leave it `""` to get them
  as a patch file in the job folder instead.
- **`jev` in `factory/settings.json`**: Jev (TypeSafe) picks the builder tier,
  skips reviewers a change gives nothing to review, and sorts review Notes.
  It is on by default in `metadata` mode, which sends facts about the work
  (file names, counts, labels); `summary` adds task titles and descriptions,
  and `"send": "off"` turns it off. Suggest `summary` for personal repos and
  `metadata` anywhere else, and tell them to check TypeSafe's terms before
  using `summary` on anything sensitive. Either needs the key in the
  environment: `export JEV_KEY=<key>`; without it each decision logs an error
  and falls back. `route`, `triage`
  and `reviewers` turn each decision off; `min_confidence` (0.7) and
  `sol_ceiling` (0.8) are the other knobs; `park_paths` adds globs whose Notes
  always go to the approver. Notes that name no path aren't guarded, and
  `jev.park_paths` extends the default list.
- **Commit**: the factory reads `AGENTS.md` from worktrees branched off
  `main`, so the install only works once it is committed on `main`. Offer to
  commit it as one commit. With `land: "pr"` worktrees branch from
  `origin/main`, not the local `main`, so the commit must also be pushed (or
  landed through a PR) before any job runs; say so, and offer to push it or
  open the PR.

**Done when** the user has answered all five.

## 7. Report

Tell the user, in a few lines:

- what was installed, and any tools still missing from step 1;
- any command in `AGENTS.md` that didn't pass in step 5;
- how to start: `/factory <feature>` for one job; `/factory import <prd>` first
  in a repo with existing beads; `factory/bin/autopilot` to drain the queue
  from a shell; `factory/bin/dashboard` for the dashboard at
  `http://127.0.0.1:4100/`.
