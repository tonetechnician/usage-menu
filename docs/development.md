# Development

## Requirements

Develop on macOS with Xcode installed. The app deployment target is macOS 14. The project is `UsageMenu.xcodeproj` and the primary scheme is `UsageMenu`.

## Make targets

Run `make help` for the current command list.

- `make build` builds the Debug app into `.build/DerivedData`.
- `make test` runs deterministic unit and integration tests.
- `make check` removes prior outputs, then builds and tests from source.
- `make diagnose` runs redacted diagnostics against local sources.
- `make diagnose-fixture` runs deterministic redacted diagnostic fixtures.
- `make live-test CODEX_PATH=/path/to/codex` opts into tests against provider-owned local sessions.
- `make package` creates and verifies an ad-hoc universal archive in `dist/`.
- `make clean` removes `.build/` and `dist/`.

`make check` is the normal pre-change and pre-commit validation. Run it from a fresh worktree when verifying a change that must not depend on local build state.

## Public synchronization path

The section's private local repository remains the source authority and orchestration history. Its commits intentionally have different IDs from the public repository. The public repository is a clean source-only history: its clean root is the base for all future public commits.

After a change lands on local `main`, replay each landed source patch in order onto an isolated public clone as an ordinary public commit. Use a reviewed `format-patch`/`git am` flow or an equivalent reviewed patch application, with the configured personal Git identity. Do not merge or graft the private graph, and do not push private refs to the public repository.

Before every public push:

1. Read back remote `main` and stop on unexpected remote movement.
2. Confirm exact final source-tree equality between local `main` and the public candidate for tracked public source.
3. Scan every reachable public commit for secrets, machine-specific paths, transcripts, artifacts, and generated output.
4. Run `make check` from a cold detached worktree.

Push normally as a fast-forward. Force pushes are exceptional: they require explicit authorization and an exact `--force-with-lease`, as used for the one-time author rewrite. Record the local-to-public SHA mapping for every replayed commit so the intentional ID difference remains auditable.

`.symphony/` is private orchestration task/runtime state. It is ignored, remains durable locally through Symphony's store and task lifecycle, and must neither create checkout dirt nor enter public Git; do not delete its local records. This deliberately differs from fleet sections that track their stores: the public boundary gives up the transfer-unit property. Public clones carry no Symphony tasks, decisions, or knowledge, and store documents have no Git history. Federation continues to read the local store from disk, so local Symphony lint and queries are unaffected. This is an accepted boundary cost, not hygiene or an accidental omission.

## Tests and source boundaries

`UsageMenuTests/` contains deterministic unit tests for the domain, store, adapters, discovery, diagnostics, and fixtures. `UsageMenuIntegrationTests/` checks the shared presentation surface. `UsageMenuTests/Fixtures/fake-codex-app-server.py` is a deterministic protocol fixture.

Default test plans disable live provider access. Live tests are explicit because they use a signed-in, provider-owned local session and can fail for local account or network reasons. They are not a replacement for deterministic tests.

Keep app implementation in `UsageMenu/`: `App/` lifecycle and composition, `Domain/` normalized model, `Store/` refresh behavior, `Providers/OpenAI/` and `Providers/Anthropic/` acquisition adapters, `UI/` presentation, and `Diagnostics/` redacted command-line output.

## Generated output and packaging

Build products, test results, diagnostic executables, and package intermediates are generated under ignored `.build/`. `make package` writes its verified local archive under ignored `dist/`; it is ad-hoc signed, performs no upload or notarization, and should not be committed. Do not add derived data, app bundles, archives, screenshots, caches, local configuration, or credentials to Git.
