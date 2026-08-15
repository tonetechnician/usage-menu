# Privacy and security

Usage Menu is deliberately narrow about what it reads and retains.

## Credential ownership

Codex authentication remains inside the provider-owned Codex app-server. Usage Menu may remember a non-secret path to the Codex executable, but does not persist, restore, refresh, or copy Codex credentials.

For the local Claude Code source, the app may read an existing provider CLI credential into request memory and send it only to Anthropic's provider-owned quota interface. It does not store, refresh, mutate, or export that credential. The interface is undocumented, so it can stop working without warning.

The app does not scrape websites, automate dashboards, extract browser cookies, copy browser sessions, or obtain credentials by any other method. It does not use a provider credential with another host.

## Local boundaries and redaction

Claude Code credential material is read from the local provider boundary, including Keychain when needed. Raw credentials, authorization headers, account emails and identifiers, private responses, prompts, and conversation content must not enter app preferences, logs, caches, diagnostics, fixtures, crash metadata, command arguments, or source control.

Normalized observations use an opaque account reference where one is necessary. The diagnostic tool reports only redacted provider, window, value, timing, status, and provenance fields. It never emits raw provider responses or authorization data.

## Distribution boundary

Release archives are built with an ad-hoc signature only. The `.zip` and `.pkg` are explicitly unsigned and not notarized, and no Apple Developer signing or notarization credential is used. Users should verify the published `SHA256SUMS`; macOS may require explicit approval before opening the app or installer. The installer package places the app in `/Applications`.

## Honest failures and freshness

A reading is current only after a successful refresh. Existing readings become stale while their source refreshes or after a source failure; unavailable, unknown, unsupported, and sign-in-required states are shown explicitly. A stale, unavailable, unsupported, or unknown reading is never rendered as zero or current.

Codex failures keep exact prior observations stale. Anthropic transient failures retain prior observations only while their reset time is still future; expired readings become unavailable. Credential and authorization failures require the user to complete the provider's own sign-in flow. The app does not attempt its own credential renewal.
