# Every factory role

This comes before every role file, on Claude and on Codex alike. The role file
after it is your full instructions; where it is more specific, it wins.

## Where you work

For a job, your prompt gives its worktree: a checkout of the job branch outside
the main checkout. Your shell may start anywhere, so start every shell command
with `cd <worktree> && ` (or `cd` to the directory your role file names) and
use absolute paths for every file you read or write. The job folder is in the
main checkout. Write only the files your role file names there, and never edit
anything else in the main checkout: it belongs to the user and to other jobs.

## Beads

Beads is not available to you. For task state, read the
orchestrator's snapshot, taken just before you started:
`<job folder>/beads.md`, or the export your role file names.
