## /factory resume <job-id>

Pick up a job whose orchestrator session ended mid-step: a closed terminal, a
crash, or a headless run stopped by its budget, a time limit or SIGTERM. Only
resume a job no other session is driving. The state is `job.json`, Beads and
the job folder; don't read more of the job than the step below needs.

1. Read the state with
   `jq -c '{stage, round, situation, decision_file, human_decision, autopilot, tasks: [.tasks[] | select(.status != "closed")]}' job.json`.
   If `stage` is `merged` or `dropped`, say so and stop. If it is
   `needs-human`, say which situation parked it and point at
   `/factory review <job-id>`, `/factory approve`, `/factory rework` and
   `/factory autopilot <job-id>`, then stop. If it is `resubmitted`, the job
   must be claimed. When your prompt says `Claimed for you by autopilot`, the
   drain already claimed it with `mkdir <job folder>/.resume-claim` and
   removes that when the job's sessions end. Otherwise claim it yourself with
   the same atomic `mkdir`. If that fails, a drain worker has it: say so and
   stop; if `pgrep -f factory/bin/autopilot` also finds no drain, the claim is
   stale, so tell the user to clear it with `rmdir <job folder>/.resume-claim`
   and resume again. Remove your own claim with `rmdir` when your session
   leaves the job. If the bead's assignee is `factory-autopilot` (a drain ran
   the job), run every `bd` write for it as `BEADS_ACTOR=factory-autopilot bd
   ...` (see **Brownfield rules**).
2. Make sure nothing from the old session is still running. If
   `pgrep -fl -- "<worktree>"` lists a `codex` or `codex-companion` process,
   stop and tell the user: another session may still own the job, or the
   process is orphaned and they should kill it. Then free the job's three
   ports (`lsof -ti tcp:<port> | xargs kill`, ignoring errors) and close its
   agent-browser sessions (`agent-browser --session <job-id>-<builder|ux|ui> close`,
   ignoring errors).
3. Check whether the job already landed:
   - With `land: "pr"`, take `pr` from `job.json`; if it is unset, look for
     a merged one with
     `gh pr list --head factory/<job-id> --state merged --json url -q '.[0].url // empty'`
     and set `pr` from it. If there is a `pr`, check it with
     `gh pr view <pr> --json state -q .state`. `MERGED`: finish **Merge** from
     its exit-0 cleanup and stop. `OPEN`: run **Merge** again (it reuses the
     PR) only when `stage` is `approve`, `decision.md`'s first line is
     `APPROVE` and `decision.md` is newer than every file in `round-<N>/`, or
     `stage` is `autopilot` and `decision_file`'s first line is `MERGE`
     (within the limits of **Autopilot decision** step 4). Otherwise carry
     on with step 4: the PR stays open across review rounds, so after a
     moved base (**Merge** exit 6) an open PR doesn't mean the approver has
     seen the new round.
   - With `land: "local"`, if `factory/<job-id>` is already merged into `main`
     (`git merge-base --is-ancestor factory/<job-id> main`), finish **Merge**
     from its exit-0 cleanup and stop. If the main checkout has a merge in
     progress for it, `git merge --abort` and go to **Merge**.
4. Check the worktree exists and
   `git -C <worktree> branch --show-current` prints `factory/<job-id>`. If the
   worktree is missing and `stage` is `spec`, create it as in step 3 of
   **/factory <feature>**. If it is missing and the job is `resubmitted` with
   a DROP decision, carry on: the drop was cut off after removing it.
   Otherwise stop and tell the user.
5. Go back in by `stage`:
   - **spec**: run the repo's setup again (AGENTS.md says it is safe to
     re-run). If `spec.md` is missing, go to step 4 of **/factory <feature>**;
     otherwise go to **Plan**.
   - **plan**: if `tasks` is empty, go to **Plan**. Otherwise the tasks were
     being filed: continue from **Plan** step 4 (filing skips tasks that
     already exist), then go to **Build**.
   - **build**: take the `in_progress` task, if there is one. If
     `build/<task-id>.md` exists, its run finished: continue from **Build**
     step 4. If not, the run was cut off: throw away its partial change
     (`git -C <worktree> reset -q --hard && git -C <worktree> clean -fdq`),
     set the task back to `open` with `runs` minus one, and go to **Build**.
     With no `in_progress` task, go to **Build**.
   - **review**: for each lens whose `round-<N>/review-<lens>.md` exists with a
     valid first line (`VERDICT: SKIPPED` is one), write its verdict to
     `job.json`. Run the missing reviewers as in **Review round N** step 2, then
     continue from step 3. With all reviews in and a `triage.md` present,
     don't run the triage command again: continue from **Triage** step 1 with
     the existing `triage.json`. Every `bd create` there is title-checked, so
     nothing is filed twice.
   - **approve**: if `decision.md` is newer than every file in `round-<N>/`,
     use it as in **Approve**. Otherwise run **Approve** again.
   - **autopilot**: if `decision_file` exists with a valid first line, continue
     from **Autopilot decision** step 3. Otherwise run step 2 with that file.
   - **resubmitted**: the owner decided in `/factory review`. Run
     `bd update <bead> --remove-label resubmitted --remove-label needs-human`,
     then act on the first line of `human_decision`. Owner decisions never change `reworks` or `respecs`.
     - **APPROVE**: go to **Merge**. A moved base still gets its re-review
       round, and **Approve** tells the approver the escalation is settled.
     - **REWORK**: file one fix task
       (`"Owner rework k"`, `-d "Address every instruction in factory/jobs/<job-id>/human-<k>.md."`)
       and a new final task depending on it, exactly as a review round does.
       Go to **Build** (resubmitting set `round_base`, so the run gets its own
       `MAX_ROUNDS`).
     - **RESPEC**: run `spec-writer` with the task
       `Amend: read human-<k>.md and revise spec.md.` Close every open task
       under the bead with `--reason "Superseded by respec human-<k>"`, then
       go to **Plan**.
     - **DROP**: take the reason from the file's `## Reason` section. Close
       every open task under the bead with `--reason "Superseded: dropped"`.
       Then `git worktree remove --force <worktree>` (if it still exists) and
       `git branch -D factory/<job-id>` (either may already be gone). With a
       `pr` whose `gh pr view <pr> --json state -q .state` is `OPEN`,
       `gh pr close <pr> --delete-branch --comment "Dropped: <reason>"`
       (after the local branch is gone, so `gh` only has the remote one to
       delete). Then `bd close <bead> --reason "Dropped: <reason>"`, set
       `stage: "dropped"`, run **Retro**, then
       `factory/bin/usage-record session <job folder>`.
6. Tell the user, in one line, where the job went back in, then carry on as
   usual. `autopilot` stays as `job.json` has it.
