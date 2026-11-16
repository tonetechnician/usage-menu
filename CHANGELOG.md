# Changelog

All notable changes to Usage Menu are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-11-16

### Fixed

- Usage Menu no longer refreshes the Claude Code sign-in, which could leave Claude Code asking for `/login` again and again. It now reads the Claude Code Keychain item first and the `.credentials.json` file only when the Keychain has no item, and shows sign-in required when the sign-in has expired. If `~/.claude/.oauth_refresh.lock` is a regular file (`ls -ld` shows `-rw…`, not `d…`), an earlier build left it behind: quit Usage Menu and delete that file so Claude Code can renew its sign-in again.

## [0.1.0] - 2026-08-15

### Added

- A macOS menu-bar view and dashboard for independently reported Codex and Claude Code quota windows.
- Explicit current, stale, unavailable, unsupported, unknown, and sign-in-required reading states.
- Local, redacted diagnostics and deterministic fixture support for supported provider sources.
