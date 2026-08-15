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
- `make validate-release` validates `VERSION`, an optional release tag, and the matching dated changelog heading.
- `make package` creates and verifies versioned universal ad-hoc `.zip` and unsigned `.pkg` outputs plus `SHA256SUMS` in `dist/`.
- `make clean` removes `.build/` and `dist/`.

`make check` is the normal pre-change and pre-commit validation. Run it from a fresh worktree when verifying a change that must not depend on local build state.

## Continuous integration

`.github/workflows/ci.yml` gates every push and pull request targeting `main`. It runs on the explicitly versioned GitHub-hosted `macos-15` arm64 image with `DEVELOPER_DIR` pinned to Xcode 16.4, asserts `uname -m` is `arm64`, prints the `xcodebuild` and `swift` versions, then runs `make check` and `make build` as separate steps.

The job holds `contents: read` only, checks out with `persist-credentials: false`, pins `actions/checkout` to a full commit SHA, and cancels superseded pull-request runs. It uses no cache, no pre-existing DerivedData, no Keychain item, no provider credential, and no absolute developer path outside the runner image; live provider tests stay disabled by the default test plan. It never packages, signs, notarizes, or uploads.

The gate mirrors what `make check` does locally, so reproduce a CI failure by running `make check` from a cold detached worktree.

## Releases

`VERSION` is the sole stable SemVer source and must contain `MAJOR.MINOR.PATCH` without pre-release or build metadata. Update it and add a dated `## [VERSION] - YYYY-MM-DD` section to `CHANGELOG.md` (Keep a Changelog format) before release. `Unreleased` remains at the top.

For a release, validate the source with `make validate-release`, run `make check` and `make package` from a cold tree, then have the release owner create and push exactly `v$(tr -d '\n' < VERSION)` after the public source replay is complete. Only `.github/workflows/release.yml`, triggered by that stable tag, publishes. It selects the pinned arm64/Xcode toolchain, validates and tests the tagged source, packages with `BUNDLE_BUILD` set to the GitHub run number, extracts matching changelog notes, verifies precisely three assets and checksums, refuses an existing release, and uses `gh` to publish. Push/PR CI remains build-and-test only.

`workflow_dispatch` is solely a recovery or rerun path for an **existing** stable tag whose release was not published. Enter that existing `release_tag`; the workflow validates it, checks out `refs/tags/<release_tag>`, and refuses to overwrite an existing GitHub Release. It is not an alternate versioning or tag-creation path.

Package outputs are `UsageMenu-<version>-universal-adhoc.zip`, `UsageMenu-<version>-universal-unsigned.pkg`, and `SHA256SUMS`. The package installs the same verified universal ad-hoc app into `/Applications`; it is deliberately unsigned and not notarized. No Apple Developer credential, signing identity, or notarization secret is used.

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

Build products, test results, diagnostic executables, and package intermediates are generated under ignored `.build/`. `make package` writes its verified versioned zip, unsigned pkg, and checksums under ignored `dist/`; it performs no upload or notarization and should not be committed. Do not add derived data, app bundles, archives, screenshots, caches, local configuration, or credentials to Git.
