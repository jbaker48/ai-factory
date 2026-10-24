# 2. Code is written by one provider and reviewed by the other

## Context

The factory could run every role on one model family, which is simpler and
needs one subscription. But a reviewer from the builder's family tends to
share its blind spots and accept what it would have written itself.

## Decision

In the default `mixed` preset an OpenAI model (Luna) builds, and the code is
checked by both providers: Sonnet reviews code, UX and UI; Astra and Sol,
different OpenAI models from the builder, take security, the adversarial
review and the approval. Every role file is provider-neutral and runs either
as a Claude subagent or through `codex exec` (`factory/bin/run-codex`), so
`models.json` moves a role between providers with a one-line change. The
single-provider presets (`claude`, `openai`) exist for people with one plan.

## Why

Uncorrelated reviewers catch more for the same number of rounds. The price is
two toolchains (Claude Code, plus the Codex CLI and plugin), a sandbox every
role must live within (no `bd`, read-only `.git`, no Chrome inside it), and
role files that can't lean on either provider's features. That neutrality is
what the presets rest on: undoing it means forking role files per provider
and losing the one-line move.
