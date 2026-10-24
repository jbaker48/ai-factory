## /factory adopt <bead>

Run the factory on a bead that already exists.

- A `feature`, `bug` or `task` that is open and not assigned to someone else
  becomes a job now. Run `/factory <its title>`, reusing it in step 2. Its
  existing children are kept: the planner reuses those that fit.
- An `epic` isn't a job. Queue its open, unassigned, non-epic children with
  `bd update <child> --add-label factory,queued` and print them.
- An `in_progress` bead whose assignee is `factory-autopilot`, when your
  prompt says `Claimed for you by autopilot as factory-autopilot.`: the
  autopilot drain claimed it for this run. Treat it as open and unassigned;
  step 2's `bd update <bead> --claim` succeeds because your session runs as
  that actor.
- Anything else `in_progress` or assigned to someone else, including a
  `factory-autopilot` bead your prompt doesn't say was claimed for you:
  refuse, say who has it, and suggest `bd dep add` so new factory work can
  wait for it.

`/factory autopilot adopt <bead>` does the same with `autopilot: true`.
