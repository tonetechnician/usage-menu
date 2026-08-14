---
schema: decision
id: 20260729-simplify-usage-hierarchy-h2v5
title: Simplify the user-facing quota hierarchy
status: decided
section: usage-menu
decision: use one Your limits dashboard plus Settings, show Weekly and returned 5-hour windows, and move internal source evidence behind Source details or Advanced
decided_by: composer
decided_at: "2026-07-29T15:15:00.000Z"
created: "2026-07-29T15:15:00.000Z"
updated: "2026-07-29T15:15:00.000Z"
---

## Ruling

Usage Menu uses one primary **Your limits** dashboard plus Settings rather than exposing internal-model navigation. Weekly is primary; the short quota window is called **5-hour** and appears only when the provider returns it.

IDs, exact provenance, interval seconds, process diagnostics, and source mechanics move behind accessible Source details or Advanced disclosure. Remaining stays the primary sign, with reset and freshness visible. OpenAI remains first and Anthropic second.

## Evidence

A transient review compared a read-only render of the landed SwiftUI dashboard with the proposed hierarchy. The Maestro requested weekly and 5-hour rather than Session, then ended review with “Awesome, go for an implementation.” The review artifact is intentionally not published; this decision is the durable record.

## Boundary

This is a presentation ruling. It does not alter provider acquisition, quota conversion, refresh lifecycle, diagnostic output, or authorize polling.
