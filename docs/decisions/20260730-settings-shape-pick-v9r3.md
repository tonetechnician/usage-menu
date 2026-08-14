---
schema: decision
id: 20260730-settings-shape-pick-v9r3
title: Which settings panel shape Sean picks in the lavish review
status: decided
section: usage-menu
question: Reviewing the lavish page, which settings panel shape should be built?
awaiting: composer
decision: build option A, the minimal preferences shape carrying only controls that do something
decided_by: composer
decided_at: "2026-07-30T13:20:00.000Z"
created: "2026-07-30T13:00:45.445Z"
updated: "2026-07-30T13:13:07.274Z"
---

## Why this is separate from s5d1

[[decisions/20260730-settings-panel-shape-s5d1]] asked which shape to adopt. Sean answered
*"give me some suggestions for panel shape with lavish. I can review there"* — which rules on **how
the answer arrives**, not what it is. That is a real ruling and s5d1 records it as decided.

But the shape itself is still unpicked, and [[tasks/20260730-settings-panel-design-s3f8]] cannot
start without it. A hold must point at something whose `status` truthfully says whether the thing
it waits on is answered, so the pick gets its own record rather than leaving s3f8 hanging off a
decision that now reads `decided`.

## How it gets answered

In the lavish page, which presents the current panel as the baseline beside the alternatives so the
comparison is something to point at rather than describe. No prose answer is needed — a pick in the
page is the answer.

## What is already settled regardless of which shape wins

Every shape carries a **Codex executable path** control showing the resolved path, whether
resolution succeeded, and an override. Discovery was fixed in code by
[[tasks/20260730-codex-executable-discovery-c9m4]], but there is still no UI to set the path when
discovery genuinely fails, and the two failure states must stay distinguishable: *Codex not found on
this Mac* versus *Configured Codex executable not found*.

The panel's current content is the defect, not its styling — it has zero interactive controls and
two sections that admit the feature does not exist. Whichever shape wins, that prose is deleted
rather than restyled.
