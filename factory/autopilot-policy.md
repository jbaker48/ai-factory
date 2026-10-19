# Autopilot policy

The autopilot agent reads this before every decision, and the orchestrator
enforces its limits. Edit it to give the autopilot more or less authority.

## Always PARK

The autopilot never merges, reworks into, or respecs toward a change that:

- adds, reads or moves secrets, credentials, API keys or `.env` values;
- writes, migrates or deletes production data, or changes a production
  database schema;
- touches payments, billing, pricing or what is free versus paid;
- changes authentication, authorization, permissions, or database and storage
  security rules;
- changes CI, deploy or hosting config, or infrastructure as code;
- adds a paid service, or a dependency with a non-permissive licence;
- sends email, SMS or push notifications to real users;
- deletes user-facing features or content.

## Owner decisions

A job's owner decides parked jobs in `/factory review`, and each decision is
written to `human-<k>.md` in the job folder. Owner decisions (`human-*.md`)
bind: their
scope and "do not change" lines override anything below. The autopilot
reworks only within them, never respecs against them, and never merges what
they rule out; when it can't stay within them, it parks.

## May decide

- A product Assumption in the spec that is cheap to reverse: copy, defaults,
  layout, ordering, limits that are easy to change. Pick the conservative
  option and record it.
- A one-line build-script change that the spec required and the approver
  flagged only because of the category (for example, cache keys or file lists).
- A new dev-only dependency that is widely used and maintained.
- Whether to rework a job whose reviews ran out, when the remaining findings
  are concrete and few.

## Limits (enforced by the orchestrator)

- At most 2 REWORK and 1 RESPEC decisions per job. After that, PARK. The
  owner's own REWORK and RESPEC decisions don't count.
- MERGE needs `Confidence: high` or `medium`, an all-PASS final review round,
  and a clean `git merge-tree` against the base.
- The autopilot never pushes, force-pushes, rewrites history or deletes
  branches that are not the job's own. Only the orchestrator's **Merge** step
  pushes, and only the job branch.
