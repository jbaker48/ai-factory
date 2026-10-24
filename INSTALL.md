# Install the factory into a project

Instructions for a coding agent installing this factory into a target repo.
`<source>` is the folder holding this file; `<target>` is the target repo's
root (`git rev-parse --show-toplevel` there). If the user hasn't said which
repo is the target, ask.

Three steps: check the tools, run the install script, then run
`/factory setup` in the target. Each ends on a **Done when**; finish it before
starting the next. The factory ships its own references and needs no external
skills plugin: its roles read only the files the install copies.

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

## 2. Run the install script

In `<target>`, first:

- `git status --porcelain` prints nothing. Uncommitted work belongs to the
  user: ask them to commit or stash it.
- The default branch is `main`. The factory lands jobs into `main` by name.
  If the default is something else, tell the user before going on.
- If `<target>` already has `.claude/skills/factory/` or `factory/`, this is
  an upgrade: show the user what `<source>/factory/bin/upgrade <target>`
  prints (the versions, the commits between them, the shipped files that
  differ and the owned files they customised; it changes nothing) and get
  their go-ahead.

Then:

```bash
<source>/factory/bin/install <target>
```

It copies the files `<source>/factory/manifest` lists as shipped over the
target's copies, writes the ones the user owns (`factory/models.json`,
`factory/autopilot-policy.md`) only when the target has none, adds the
factory's `.gitignore` lines, and writes `factory/VERSION`: the source commit
SHA. It refuses a source with uncommitted changes (untracked files included)
in its shipped files, since `VERSION` would not describe them: commit or
discard them first. It never touches `factory/settings.json`; `/factory
setup` writes it.

**Done when** `ls <target>/factory/bin` lists `run-codex`, `run-adversarial`,
`job-set` and `autopilot`, all executable, and `git -C <target> status`
shows no file under `factory/jobs/` other than `.gitkeep`.

## 3. Run /factory setup

Start a Claude Code session in `<target>` and run `/factory setup`
(`.claude/skills/factory/setup.md`). It initialises or keeps Beads, writes
`AGENTS.md` and proves its commands in a fresh worktree, then asks the user
each decision (the autopilot policy, the model preset, the settings, Jev's
send mode and the install commit) and ends with a report. Running it again
later refreshes the factory's sections of `AGENTS.md` and offers each earlier
answer as the default.

**Done when** `/factory setup` has reported, and the user knows about any tool
still missing from step 1.
