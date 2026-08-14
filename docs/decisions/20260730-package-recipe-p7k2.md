---
schema: decision
id: 20260730-package-recipe-p7k2
title: Whether the ad-hoc universal package recipe becomes a committed script
status: decided
section: usage-menu
question: May a Make package target that reproduces today verified ad-hoc universal artifact be committed, given that distribution is otherwise outside the proven slice?
awaiting: composer
decision: provide a Make package target, ad-hoc only, that refuses to emit an artifact whose signature or slice set does not verify
decided_by: composer
decided_at: "2026-07-30T13:25:00.000Z"
created: "2026-07-30T10:45:24.459Z"
updated: "2026-07-30T13:14:08.909Z"
---

## What is actually being asked

Sean now runs this app on a second Mac, and getting it there took a build recipe that lives
nowhere: release configuration, universal (`arm64` + `x86_64`), `codesign -s -` deep, then
`ditto -c -k --sequesterRsrc --keepParent`. I ran that recipe by hand today and verified the
artifact. Nothing in the repo records it.

The charter says distribution "remains outside the proven slice until separately ruled". So the
obvious next step — publish a package workflow that reproduces today's artifact — is exactly the
boundary I am told not to cross on my own. Hence the ask.

## The cost of leaving it uncommitted

Every future hand-off re-derives four flags from memory. Two of them fail silently rather than
loudly: a plain `zip` instead of `ditto` mangles the bundle's symlinks and permission bits and
produces an app that will not launch, and the failure presents as a signing problem; and
`ONLY_ACTIVE_ARCH` left at its default silently yields an arm64-only build that is fine here and
dead on an Intel Mac. Both are the shape this section exists to refuse — a wrong answer that
looks like a working one.

## Options

- **A — provide `make package`.** One Make target, ad-hoc sign only, no credentials, no
  notarization, no upload. It emits the zip and refuses to emit one whose signature or slice set
  does not verify. This does not open the distribution movement; it records a recipe already ruled.
- **B — record the recipe in `README.md` as prose only.** Cheaper, no new executable surface,
  but prose does not fail. A reader who skips the `ditto` line gets a broken app and no signal.
- **C — leave it entirely unrecorded** until distribution is ruled as a movement. Honest about
  the boundary, and it means the next hand-off is another manual reconstruction.

## Recommendation

**A.** The distribution prohibition is about *shipping to other people* — notarization, Developer
credentials, an update channel. Sean's own second Mac under his own already-ruled ad-hoc exception
is not that, and a script that verifies its own output is the section's own standard applied to
its own build, not a widening of scope. If A reads as too close to the line, B beats C: a recipe
written down badly still beats one held only in a session that ends.
