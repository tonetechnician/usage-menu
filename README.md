# Usage Menu

[![CI](https://github.com/tonetechnician/usage-menu/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/tonetechnician/usage-menu/actions/workflows/ci.yml)

Usage Menu is a native macOS menu-bar app for checking the usage limits that supported AI provider sources can actually report.

The menu and dashboard show independent Codex and Claude quota windows, their remaining or used values, reset times when supplied, and an explicit freshness state. This makes the nearest known constraint easy to check without treating unrelated subscriptions, limits, or billing scopes as one number.

## Support and limits

- **OpenAI Codex:** reads the signed-in, provider-owned Codex `app-server` locally.
- **Anthropic Claude Code:** reads the existing local Claude Code sign-in only in request memory and queries an undocumented provider-owned quota interface. It is a fragile, local-only source and may be unavailable.
- The app does not support general provider dashboards, browser automation, API billing aggregation, history, polling, or widgets in this release.

No website scraping or browser-cookie copying is used. Provider CLI credentials remain provider-owned and are used only in request memory. Stale or unavailable readings are labelled as such; they never become zero or current.

## Build and run

Requirements: macOS 14 or later with Xcode installed. Build and run the deterministic checks:

```sh
make check
open -na .build/DerivedData/Build/Products/Debug/UsageMenu.app
```

Use `make help` for all supported commands. For a signed-in local Codex source, pass `--codex-path /path/to/codex` when launching the app; `--fixture` explicitly selects deterministic sample data.

## More detail

- [Architecture and data flow](docs/architecture.md)
- [Development](docs/development.md)
- [Privacy and security](docs/privacy-and-security.md)
- [Implementation guidance](AGENTS.md)
