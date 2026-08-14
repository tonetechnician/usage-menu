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

## Tests and source boundaries

`UsageMenuTests/` contains deterministic unit tests for the domain, store, adapters, discovery, diagnostics, and fixtures. `UsageMenuIntegrationTests/` checks the shared presentation surface. `UsageMenuTests/Fixtures/fake-codex-app-server.py` is a deterministic protocol fixture.

Default test plans disable live provider access. Live tests are explicit because they use a signed-in, provider-owned local session and can fail for local account or network reasons. They are not a replacement for deterministic tests.

Keep app implementation in `UsageMenu/`: `App/` lifecycle and composition, `Domain/` normalized model, `Store/` refresh behavior, `Codex/` and `Anthropic/` acquisition adapters, `UI/` presentation, and `Diagnostics/` redacted command-line output.

## Generated output and packaging

Build products, test results, diagnostic executables, and package intermediates are generated under ignored `.build/`. `make package` writes its verified local archive under ignored `dist/`; it is ad-hoc signed, performs no upload or notarization, and should not be committed. Do not add derived data, app bundles, archives, screenshots, caches, local configuration, or credentials to Git.
