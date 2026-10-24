## /factory review [<job-id>]

Work through parked jobs with their owner, one at a time, and end each with a
recorded decision that sends it back to the drain. This session never runs a
job's build, review or merge. It needs a person: in a headless session, say so
and stop.

Take the jobs at `stage: "needs-human"`, oldest `updated` first
(`jq -r 'select(.stage == "needs-human") | "\(.updated) \(.id)"' factory/jobs/*/job.json | sort`).
With `<job-id>`, take only that job, and if its stage isn't `needs-human`,
say which stage it is at and stop. For each job, pick `k`, the next number
with neither `human-brief-<k>.md` nor `human-<k>.md` in its folder. A
`human-<j>.md` numbered above the one `human_decision` names (any, when it is
unset) was never resubmitted, from a review that was cut off: move it to
`.runs/human-<j>.abandoned.md` first, so no later role takes it as binding.

1. **Brief.** Run `factory/bin/beads-snapshot <job folder>`, then `briefer`
   with the task `Brief k.` (then `usage-record claude <job folder> briefer`,
   as after every Claude role). Check `human-brief-<k>.md` exists and starts
   with `## Situation`. Read only this brief, never the raw job files, so your
   context stays small across many jobs.
2. **Ask.** Show the `## Situation` in a few lines. Ask each question under
   `## Decisions` with AskUserQuestion, one question per decision, its options
   as the choices and the recommended one marked; the owner may answer
   free-form. Then confirm the outcome, **approve**, **rework**, **respec** or
   **drop** (only those the brief offered), and which `## Out of scope` beads
   to file. For drop, ask for a one-line reason.
3. **Record.** Run `briefer` with the task
   `Write decision k. Owner answers: <every question, its answer, the outcome and any reason, verbatim>`.
   If it finishes with `NEEDS-OWNER: <question>`, ask the owner that question
   and run `Write decision k.` again with all the answers so far. Check
   `human-<k>.md` exists and its first line is `APPROVE`, `REWORK`, `RESPEC`
   or `DROP`; never resubmit without one. File each chosen out-of-scope bead,
   unless an open bead already has its title
   (`bd list --title "<title>" --json | jq -r --arg t "<title>" '.[] | select(.title == $t) | .id'`;
   reuse that id instead):
   ```bash
   bd create "<title>" --type=<type> -p <priority> -l factory,queued \
     -d "<description>

   Found by /factory review of factory/<job-id>." --silent
   ```
   Then put their ids (or `None.`) in place of the file's `Pending:` line:
   `perl -pi -e 's/^Pending:.*/<ids>/' <job folder>/human-<k>.md`.
4. **Resubmit.** `rmdir <job folder>/.resume-claim` if one is left over (it
   is stale: a parked job has no worker). In one `job-set`:
   `stage: "resubmitted"`, `human_decision: "human-<k>.md"`,
   `situation: null`, `autopilot: true`, `round_base` set to `round`. Then
   `bd update <bead> --remove-label needs-human --add-label resubmitted`,
   and move on to the next job.

Then, without a job id, take the `needs-human` beads that no job folder's
`job.json` names: import conflicts, which are questions rather than code, so
there is no briefer. For each, show the `PRD conflict:` comment from
`bd comments <bead>` and ask the owner. Write the answer, verbatim, with
`bd comment <bead> "Owner decision: <answer>"`, and into the description too
if it changes what the bead asks for and the factory created the bead (see
**Brownfield rules**). Then, if the bead is `in_progress` or assigned to
someone else, only `bd update <bead> --remove-label needs-human`: its owner
has it, so it isn't queued. Otherwise
`bd update <bead> --remove-label needs-human --add-label factory,queued`.

At the end, print one line per job or bead handled: id, outcome, and the
beads filed. Then the **drain check**: if `pgrep -f factory/bin/autopilot`
finds a drain, say it will pick the jobs up. If not, offer to start
`factory/bin/autopilot --watch` with Bash and `run_in_background: true`; it
resumes resubmitted jobs and keeps watching for more.
