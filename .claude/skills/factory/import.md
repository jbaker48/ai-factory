## /factory import <prd>

Bring a PRD into a repo that already has beads, without duplicating or
trampling work in flight.

1. Create `factory/imports/<YYYY-MM-DD>-<prd-slug>/` (gitignored, like
   `factory/jobs/`).
2. Run `bd --readonly export -o <import folder>/beads.jsonl`: the importer
   reads every bead from it. Then run `importer` with the task
   `Repo: <repo>. PRD: <absolute prd path>. Import folder: <absolute folder>.`
   in place of `<paths> <task>`: it has no job, worktree or bead. For an
   OpenAI role, call `run-codex` with the import folder as `<job folder>` and
   `<repo>` as `<worktree>`.
3. Read `import.json` (stop if it isn't valid JSON) and show the user a table:
   per action, the beads and titles, then the conflicts in full. Unless the
   command was `/factory autopilot import <prd>`, ask once for go-ahead and
   apply only what they accept.
4. Apply it, in this order:
   - **create**: `bd create "<title>" --type=feature -l factory,queued -p <priority> --silent`
     with `-d "<description>\n\nPRD: <prd> § <prd_section>"`. Note each
     key's new id.
   - **adopt**: skip it if the bead is now `in_progress` or assigned. Otherwise
     `bd update <bead> --add-label factory,queued`, plus
     `bd comment <bead> "PRD <prd> § <prd_section>: <context>"` when there is
     context.
   - **depends_on** for create and adopt items, with keys resolved to ids:
     `bd dep add <item> <dependency>`.
   - **conflict**: `bd comment <bead> "PRD conflict: <reason>"` and
     `bd update <bead> --add-label needs-human`. Queue nothing for it.
   - **done** and **owned**: write nothing.
5. Write `applied.md` in the import folder: what was created, adopted and
   flagged, with ids. Then print the new ready queue. The work runs through
   `/factory next` or `/factory autopilot` like any other queued job.

On autopilot, conflicts still get `needs-human`: the autopilot decides about
jobs, not about contradictions between a PRD and someone else's bead.
