---
schema: decision
id: 20260729-local-private-quota-q4m8
title: Local quota credential and interface boundary
status: decided
section: usage-menu
decision: local quota observation may use in-memory provider CLI credentials and undocumented provider-owned quota interfaces within the recorded non-persistence and failure-semantics limits
decided_by: composer
decided_at: "2026-07-29T08:24:23.000Z"
created: "2026-07-29T08:24:23.000Z"
updated: "2026-07-29T08:24:23.000Z"
---

## Ruling

Usage Menu is a local-only personal application. For quota observation only, it may read an existing provider CLI credential into process memory and use that credential only with the provider that owns it. It may call an undocumented provider-owned quota interface when the Maestro has explicitly accepted that interface's fragility.

This is a narrow exception. It does not permit browser-cookie extraction, DOM or UI scraping, credential mutation, credential refresh, copying credentials into Usage Menu storage, account impersonation beyond the provider CLI's own protocol, or sending a credential to any host other than its owning provider.

## Evidence and tradeoff

Quota Axi v0.1.16 at `335be6f7ccbb637feb1e0c2b4d30268af41f9f4f` demonstrated a read-only Claude Code OAuth flow using the provider-owned credential and Anthropic OAuth usage interface. That interface is not publicly documented and can change without notice. The Maestro prefers useful local subscription telemetry over official-interface stability for this personal tool.

The old boundary remains part of the historical record because it correctly described the previous risk decision. This ruling changes that decision rather than pretending it never existed.

## Operational constraints

- Raw credentials and raw private responses are ephemeral and never enter logs, caches, defaults, fixtures, diagnostics, crash metadata, Markdown, or command arguments.
- Failures are redacted and become unavailable/auth-required on first failure or stale after prior success; they never become zero or current.
- Session, weekly, model-specific, and extra-usage windows retain independent identities and reset horizons.
- The UI discloses the local Claude Code credential source and undocumented provider interface.
- OpenAI remains first and Anthropic second.
