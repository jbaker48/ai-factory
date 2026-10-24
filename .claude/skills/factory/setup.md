## /factory setup

Get this repo's Beads and `AGENTS.md` ready for the factory, after
`factory/bin/install` has copied the factory in, then take the user's
decisions. Run it from the repo's main checkout. It is safe to run again: a
re-run updates the factory's sections of `AGENTS.md` in place, leaves the
user's own content as it is, and offers each earlier answer as the default.

Work through the steps in order. Each ends on a **Done when**; finish it
before starting the next. In a headless session nobody can accept a failure:
report it and stop.

A factory section of `AGENTS.md` is the text from
`<!-- factory:begin <name> -->` to `<!-- factory:end <name> -->`, the markers
on lines of their own. Everything outside the markers belongs to the user (or
to Beads): on a re-run you never change it.

### 1. Beads

- **No `.beads/`**: run `bd init`. It also writes its own integration files
  (an `AGENTS.md` section, a `CLAUDE.md`, editor rules, a Beads skill); note
  each file it creates or changes for step 2.
- **`.beads/` exists**: keep it. People and other tools share it. Tell the
  user the brownfield path: `/factory import <prd>` maps a PRD onto the
  existing beads before any job runs.

**Done when** `bd --readonly ready` runs in the target without an error.

### 2. AGENTS.md

Every factory role reads `AGENTS.md` first, and the role files carry nothing
repo-specific, so this step decides whether jobs work at all. Start from
`factory/AGENTS.template.md`. Its header comment lists the conditions the
commands run under; read it before writing anything.

1. **Gather the facts from the repo**: package manager and lockfile, toolchain
   pins (`.nvmrc`, `.tool-versions`, `pyproject.toml`), scripts in
   `package.json` or the `Makefile`, the CI workflow (its steps are usually the
   truest validation commands), `.env.example`, `docker-compose.yml`, and the
   docs folder, including a glossary and an ADR folder for the template's
   `## Domain docs` section. On a re-run, also read the current text of each factory
   section: the user may have corrected it, and a correction the repo still
   bears out stays.
2. **Write the factory sections.** Fill every `<...>` of the template's
   sections, keep their markers, and leave out the header comment.
   - **First run** (`AGENTS.md` is missing or has no `factory:begin` marker):
     write `AGENTS.md` yourself. The template's sections come first, in its
     order. Existing `AGENTS.md` or `CLAUDE.md` content a template section
     covers is merged into that section; content none covers, Beads' section
     included, follows them outside the markers.
   - **Re-run**: write the sections to a scratch file outside the repo and run
     `factory/bin/agents-md apply AGENTS.md <file>`. It replaces each section
     in place, appends any section the file lacks (one the template has gained
     since), and leaves every line outside the markers as it was. If it
     reports unbalanced markers, show the user the line it names and stop;
     don't guess at a repair.
3. **Make `CLAUDE.md` the one line `@AGENTS.md`.** If it has content of its
   own, merge that into `AGENTS.md` first, outside the markers unless a
   factory section covers it.
4. **Scope Beads' own section to people.** If `bd init` added instructions
   telling agents to claim, close, commit or push, put a factory section named
   `beads-scope` directly above Beads' section: it says that section is for
   people working by hand, that factory agents read Beads only
   (`bd --readonly`), and that commits and Beads writes are left to the
   orchestrator. Don't edit Beads' section itself. On a re-run, include
   `beads-scope` in the scratch file only if `AGENTS.md` already has it;
   otherwise add it by hand above Beads' section, so it never lands at the end.
5. **Prove the commands in a fresh worktree**, the way the factory will run
   them. Write a commands file outside the repo, one command per line, in
   this order: the setup commands; every validation command in its whole-repo
   form and its scoped form, with a real file or path in place of each
   placeholder; and one line that starts the dev server on port `5199` in the
   background, waits for its readiness check, checks that the server is
   listening on exactly port `5199`, and kills it. Then run
   `factory/bin/agents-md check . <file>`. It runs each line in a fresh
   worktree of `HEAD` with your uncommitted `AGENTS.md` copied in, prints
   `PASS` or `FAIL (exit N)` per line with the tail of each failure's output,
   and removes the worktree. A command that fails here fails in every job:
   fix the command or the setup in `AGENTS.md`, and rerun until it passes, or
   name the failure to the user and ask whether to accept it.

**Done when** `AGENTS.md` has no `<...>` left, every command in it passed in
the fresh worktree (or the user has accepted a named failure), and the dev
server bound exactly port `5199`.

### 3. Decisions

The user decides how the factory behaves. Run `factory/bin/decisions` first:
it prints the current value of each decision from the repo's files (on a
first run, the shipped defaults). Present the five decisions one at a time,
with the current value as the default, and wait for their answer before
recording it and moving on; an answer that keeps the default changes nothing.
In a headless session nobody can answer: report the current values and stop.

1. **Autopilot policy** (`factory/autopilot-policy.md`, printed as its count
   of Always PARK rules): what the autopilot may merge without a person.
   Point out the project's own sensitive areas (from `AGENTS.md`) that the
   policy doesn't yet name, and offer to add them under `## Always PARK`. A
   policy customised before `SKIPPED` existed needs the same change: MERGE
   needs every final-round review `PASS` or `SKIPPED`, not "all-PASS".
2. **Model preset** (`factory/models.json`, printed as `preset`): the model
   and effort per role. Ask which subscriptions they have and run the matching
   preset: both, `factory/bin/models mixed` (the default; `factory/bin/models
   lean` spends less quota); Claude only, `factory/bin/models claude` (no
   Codex CLI or plugin); ChatGPT only, `factory/bin/models openai` (no Codex
   plugin, but the orchestrator is still Claude Code). For `mixed`, `lean`
   and `openai`, confirm their Codex account can use the OpenAI models listed.
   A `custom` preset is the user's hand edit: keep it unless they pick a
   preset, then pass `--force`.
3. **Settings** (`factory/settings.json`): write it from
   `factory/settings.example.json` if `settings` printed `not written`, and
   record each answer with `jq`, keeping every other key.
   - `land`: does the repo have a GitHub remote? Yes sets `"land": "pr"`, no
     sets `"land": "local"`.
   - `priority_labels`: which labels mark high-priority beads (`[]` for none).
   - `jobs`: leave it at 1 unless they want parallel jobs. `jobs` is how many
     jobs `factory/bin/autopilot` runs at once (`--jobs N` overrides it per
     run).
   - `factory_source`: optional, the absolute path of a local ai-factory
     checkout, where retros open PRs with factory fixes; leave it `""` to get
     them as a patch file in the job folder instead.
4. **Jev's send mode** (`jev.send` in `factory/settings.json`): Jev
   (TypeSafe) picks the builder tier, skips reviewers a change gives nothing
   to review, and sorts review Notes. It is on by default in `metadata` mode,
   which sends facts about the work (file names, counts, labels); `summary`
   adds task titles and descriptions, and `"send": "off"` turns it off.
   Suggest `summary` for personal repos and `metadata` anywhere else, and tell
   them to check TypeSafe's terms before using `summary` on anything
   sensitive. Either needs the key in the environment: `export
   JEV_KEY=<key>`; without it each decision logs an error and falls back.
   `route`, `triage` and `reviewers` turn each decision off; `min_confidence`
   (0.7) and `sol_ceiling` (0.8) are the other knobs; `park_paths` adds globs
   whose Notes always go to the approver. Notes that name no path aren't
   guarded, and `jev.park_paths` extends the default list.
5. **Install commit** (printed as `commit`): the factory reads `AGENTS.md`
   from worktrees branched off `main`, so the install only works once it is
   committed on `main`. Offer to commit it as one commit. With `land: "pr"`
   worktrees branch from `origin/main`, not the local `main`, so the commit
   must also be pushed (or landed through a PR) before any job runs; say so,
   and offer to push it or open the PR. Ask this last, so the commit holds
   the other answers.

**Done when** the user has answered all five, and each answer is in its file
or committed.

### 4. Report

Tell the user, in a few lines: whether Beads was initialised or kept; whether
`AGENTS.md` was written or which factory sections changed; every command that
failed in step 2, as `check` printed it, with whether the user accepted it;
each decision that changed; and how to start: `/factory <feature>` for one
job, `/factory import <prd>` first in a repo with existing beads,
`factory/bin/autopilot` to drain the queue from a shell, and
`factory/bin/dashboard` for the dashboard at `http://127.0.0.1:4100/`.
