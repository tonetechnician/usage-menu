---
schema: decision
id: 20260730-settings-panel-shape-s5d1
title: Which settings panel shape Usage Menu adopts
status: decided
section: usage-menu
question: "Which settings panel shape should Usage Menu adopt: A minimal preferences, or B source diagnostics?"
awaiting: composer
decision: present two or three panel shapes plus the current baseline in a lavish page for review there, rather than picking a shape from prose
decided_by: composer
decided_at: "2026-07-30T13:00:00.000Z"
created: "2026-07-30T12:32:27.521Z"
updated: "2026-07-30T13:00:00.631Z"
---

## Why you are being asked to point rather than describe

You said the settings panel *"looks crap"*. That is a real signal and not a specification, so
rather than guess at a rewrite, two concrete alternatives were prepared for review. They were
transient review artifacts, not product source, and are intentionally absent from the published
repository. The ruling and its implementation remain durable here.

## The diagnosis behind them

The panel does not need restyling. `UsageSettingsView` has **zero interactive controls** — three
`Form` sections of static prose, two of which admit the thing they describe does not exist
("Customize readings controls are not available yet.", "Automatic refresh — Off / not available
yet"). **Both options delete that prose rather than restyle it,** and both add the one control the
panel must have: a Codex executable path with its resolved state and an honest failure case.

## Options

- **A — Settings as minimal preferences.** Only what is real: the Codex path control plus read-only
  identity, as a small native inset-grouped list in the System Settings idiom. Calmest to read,
  cheapest to build, stays close to the old footprint. Says less: if Anthropic specifically breaks,
  this panel gives a one-line badge and you go back to the dashboard to dig.
- **B — Settings as source diagnostics.** Reorganized around the two provider sources, mirroring the
  dashboard's own Source details / Advanced language, with the Codex path control inside OpenAI's
  own health card next to the consequence it explains. Answers "why is this reading missing?"
  without leaving Settings, and extends cleanly per source. Denser, 560px wide, and deliberately
  duplicates some of what the dashboard already shows.

## Recommendation

**A**, with a caveat that is really a question about you rather than about the design.

A is right if Settings stays a small pane you rarely open and the dashboard remains the one place
for status. **B is right if Settings is the first place you would go when a reading looks wrong** —
and given that the defect that started this was exactly a source failing silently, that is not a
far-fetched workflow. The honest split is: A is the better default, B is the better answer if you
expect to debug from here. Only you know which you would actually do.

Either way the Codex path control ships, because
the Codex executable-discovery implementation fixed discovery in code but left no way to override
it from the UI when discovery genuinely fails.
