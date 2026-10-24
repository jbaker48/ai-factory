## /factory setup

Get this repo's Beads and `AGENTS.md` ready for the factory, after
`factory/bin/install` has copied the factory in. Run it from the repo's main
checkout. It is safe to run again: a re-run updates the factory's sections of
`AGENTS.md` in place and leaves the user's own content as it is.

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
   docs folder. On a re-run, also read the current text of each factory
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

### 3. Report

Tell the user, in a few lines: whether Beads was initialised or kept; whether
`AGENTS.md` was written or which factory sections changed; and every command
that failed in step 2, as `check` printed it, with whether the user accepted
it.
