## /factory retro <job-id>

Run **Retro** on one job by hand, at any stage and even if it isn't due:
skip `retro-due`. Use it on old jobs, and to finish a retro that failed or
was cut off. If `job.json` `retro_worktree` is not null and `retro.md`'s
first line passes step 4, a publish was cut off: run only step 5 and step 6
(`factory/bin/retro-publish <job folder>`), not prep or the role. Otherwise
running it again replaces `retro.md` and reuses the open retro PRs and any
unpublished retro branch.
