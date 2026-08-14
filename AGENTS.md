# Working on Usage Menu

## Preserve these invariants

- Keep provider readings independent. Never combine consumer subscriptions, organization billing, credits, rate limits, or windows into a synthetic allowance.
- Preserve the provider-neutral observation scope and provenance. Derive a value only when its source scope matches exactly.
- State is semantic: `current`, `stale`, `unavailable`, `auth-required`, `unsupported`, and `unknown` must remain distinguishable. Never turn missing, failed, stale, or unsupported data into zero or current data.
- `UsageStore` is the shared, single-flight refresh boundary. Menu, dashboard, startup, activation, and manual refresh must use it rather than adding competing refresh paths.
- Do not introduce polling without a deliberate design and tests; this release refreshes at startup, activation, and on user request.

## Source and credential rules

- Do not scrape provider websites, automate browsers, or extract/copy browser cookies.
- Codex authentication belongs to the provider-owned app-server. Claude Code credentials may be read only into request memory for Anthropic's provider-owned local quota request.
- Never persist, log, fixture, diagnose, pass on command lines, or commit credentials, authorization values, raw private responses, account-private identifiers, prompts, or conversation content.
- Keep diagnostics redacted and normalized. Preserve the distinction between provider acquisition and UI presentation.

## Implementation map

- `UsageMenu/App/`: application composition and lifecycle ownership.
- `UsageMenu/Domain/`: normalized observations and reading states.
- `UsageMenu/Store/`: refresh, failure, and freshness transitions.
- `UsageMenu/Providers/OpenAI/` and `UsageMenu/Providers/Anthropic/`: provider-specific acquisition.
- `UsageMenu/UI/`: SwiftUI views and accessibility text.
- `UsageMenu/Diagnostics/`: redacted command-line diagnostics.
- `UsageMenuTests/` and `UsageMenuIntegrationTests/`: deterministic coverage; live access is explicit only.

## Workflow

Run `make check` for ordinary validation. Use `make diagnose-fixture` for deterministic diagnostic output; use `make live-test CODEX_PATH=/path/to/codex` only when intentionally testing a local provider session. `make package` produces a verified local ad-hoc archive only.

Keep generated output in ignored `.build/` or `dist/`. Do not commit build products, app bundles, archives, screenshots, caches, local configuration, machine-specific paths, runtime records, or generated visual previews. Documentation visuals should be source text, such as Mermaid, with prose that conveys the same meaning.

## Public synchronization

The private local repository is the section's source authority and orchestration history. The public repository is a clean source-only history whose clean root is the base for future public commits; private and public commit IDs intentionally differ.

After work lands locally, replay each landed source patch in order in an isolated public clone as an ordinary public commit, using the configured personal Git identity. Use reviewed `format-patch`/`git am` or an equivalent reviewed patch application. Never merge or graft the private graph, and never push private refs.

Before every public push:

1. Read back remote `main` and stop on unexpected movement.
2. Verify exact final source-tree equality between local `main` and the public candidate for tracked public source.
3. Scan all reachable public commits for secrets, machine paths, transcripts, artifacts, and generated output.
4. Run `make check` from a cold detached worktree.

Push fast-forward normally. A force push requires explicit authorization and exact `--force-with-lease`; it is exceptional, as in the one-time author rewrite. Record the local-to-public SHA mapping for each replayed commit.

`.symphony/` is ignored private orchestration task/runtime state. Keep its local records durable through Symphony's store and task lifecycle, but never allow it to create checkout dirt or enter public Git; do not delete it. This deliberately differs from fleet sections that track stores: the public boundary gives up the transfer-unit property, so public clones contain no tasks, decisions, or knowledge and store documents have no Git history. Federation still reads the local store from disk; local Symphony lint and queries are unaffected. Treat this as an accepted boundary cost, not hygiene or an accidental omission.
