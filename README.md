# Usage Menu — Project Requirements Document

## 1. Product summary

Usage Menu is a native macOS utility for viewing supported OpenAI and Anthropic usage signals without opening multiple dashboards. Its primary surface is a compact SwiftUI menu-bar extra. A detail window provides source setup, diagnostics, and history; an optional desktop widget may follow after the data model is proven.

The product must report only what a source can establish. It must never turn missing, delayed, unsupported, or differently scoped data into a reassuring but false percentage.

## 2. User problem

A person using several AI products may have multiple independent constraints:

- consumer subscription allowances;
- rolling or weekly model windows;
- API organization usage and cost;
- short-window request and token rate limits;
- provider-specific credits or spending caps.

These values live in different interfaces, use different signs (`used` versus `remaining`), reset on different schedules, and are not always available through supported APIs. The user needs a glanceable answer to “what is closest to constraining me?” while retaining enough provenance to understand what the answer means.

## 3. Product principles

1. **Honesty before coverage.** Unsupported data is labelled unsupported; errors never become zero.
2. **Sources remain distinct.** Consumer subscriptions, API billing, credits, and rate limits are not combined into one allowance.
3. **Semantics are explicit.** Every value names whether it is used, remaining, a limit, a cost, or a derived value.
4. **Freshness is visible.** Every observation carries its source and observation time.
5. **Secrets stay local.** App-owned credentials are stored in macOS Keychain. Provider CLI credentials may be read into memory only under the ruled local-observation exception; no credential enters Usage Menu storage, logs, widgets, caches, diagnostics, or source control.
6. **The menu answers quickly.** Detailed analysis belongs in a window, not in a crowded menu-bar panel.

## 4. Supported data boundary

### 4.1 Supported candidates

The initial implementation may use only documented provider interfaces:

- OpenAI Codex subscription rate-limit and usage information exposed through the documented Codex app-server interface;
- OpenAI API organization usage and cost endpoints, where the user can provide an appropriately scoped Admin API key;
- Anthropic API organization usage and cost endpoints, where the user can provide an appropriately scoped Admin API key;
- rate-limit headers observed on API responses where a supported integration can supply them.

### 4.2 Unsupported unless an official interface or ruled local exception appears

- general ChatGPT consumer model/message allowances;
- Claude Pro or Max consumer allowance telemetry, except through the local-only exception below.

The original product boundary prohibited browser cookies, private web endpoints, DOM or network scraping, copied CLI credentials, and automated interaction with provider dashboards. That was the correct risk posture before Usage Menu became an explicitly local-owned personal tool. It remains the historical baseline rather than being edited out of the record.

### 4.3 Ruled local-only quota exception

The Maestro changed the credential and private-interface boundary in [[docs/decisions/20260729-local-private-quota-q4m8]]. For local quota observation only, Usage Menu may read an existing provider CLI credential into process memory and call an undocumented provider-owned quota interface.

This exception permits Claude Pro/Max quota retrieval from the local Claude Code session. It does **not** permit browser-cookie extraction, DOM or UI scraping, credential mutation or refresh, copying a credential into Usage Menu storage, account impersonation beyond the provider CLI's own protocol, or sending credentials anywhere except the provider that owns them. Raw credentials and raw private responses must be discarded and must never enter logs, caches, defaults, diagnostics, fixtures, crash metadata, or source control.

Undocumented interfaces are explicitly fragile. A first failure is unavailable or auth-required; a failure after success retains only sanitized prior observations as stale. Failures never become zero or current. A future manual observation may be displayed only as `user_entered` and must remain distinguishable from provider-derived data.

## 5. MVP requirements

### 5.1 Menu-bar surface

The application shall provide a SwiftUI `MenuBarExtra` that:

- identifies the nearest supported constraint;
- shows provider, product surface, remaining or used value, reset time where known, and freshness;
- supports manual refresh;
- opens the detail window;
- preserves independent provider failures;
- displays `stale`, `unavailable`, `unsupported`, and `unknown` explicitly.

The menu-bar label should default to a compact status icon. Showing a percentage or amount in the menu bar must be optional.

### 5.2 Detail and settings window

The application shall provide a standard SwiftUI window for:

- adding, replacing, and removing source credentials;
- viewing every known constraint without collapsing reset windows;
- viewing source health, last successful refresh, and redacted errors;
- choosing refresh intervals;
- configuring privacy and display preferences.

### 5.3 Data acquisition

- Provider adapters shall run independently.
- A failure in one adapter shall not hide current data from another.
- Polling shall avoid overlapping requests and respect provider throttling and `Retry-After` guidance.
- The initial polling interval should be configurable, with a conservative default between five and fifteen minutes.
- Manual refresh shall be available and rate-limited sensibly.

### 5.4 Security

- App-owned secrets shall be stored as separate macOS Keychain items. Provider CLI credentials used under the ruled local-only exception remain provider-owned, are read into memory only, and are never copied into Usage Menu storage.
- Secrets, authorization headers, raw private responses, account emails, account identifiers, prompts, and conversation content shall not be logged.
- Cached snapshots shall contain only values required for display.
- The application shall use App Sandbox outgoing-network permission and no broader entitlement unless a concrete feature requires it.
- Organization-wide Admin keys shall be described as high-impact credentials before the user adds one.

### 5.5 Accessibility

- Every visual gauge shall have a complete VoiceOver description.
- Colour shall not be the sole carrier of status.
- Used and remaining bars shall never use contradictory fill directions.
- Dynamic Type, increased contrast, keyboard navigation, and Reduce Motion shall be respected where macOS exposes them.

## 6. Provider-neutral observation model

Each observation must preserve at least:

```text
provider
account_reference
product_surface: consumer | organization | workspace | project
kind: usage | quota | rate_limit | cost | credit_balance
resource and unit
used, remaining, and limit as independently optional values
interval or window duration
window_started_at and reset_at when known
observed_at and source_generated_at when known
provenance: source method and raw field names
status: known | stale | unavailable | unsupported | unknown | error
confidence: authoritative | derived | user_entered
```

A derived remaining value may be calculated only when used and limit share the same provider, account scope, resource, interval, and provenance. The original observations must remain available.

## 7. macOS architecture constraints

The initial product shall be a native SwiftUI application:

- `MenuBarExtra` for the primary surface;
- a standard detail/settings window;
- `URLSession` and structured concurrency for network adapters;
- Keychain Services for secrets;
- a local sanitized snapshot cache;
- explicit launch-at-login control using supported Service Management APIs.

WidgetKit is not part of the MVP. If added later, it shall consume sanitized cached snapshots through an App Group, display snapshot age, and never act as the polling engine. A floating utility panel may be explored later as an opt-in always-visible surface.

## 8. Non-goals for the first release

- Circumventing or automating provider limits.
- Scraping provider websites.
- Reading conversation content.
- Team billing administration or invoice replacement.
- A single synthetic score combining unrelated products.
- Minute-by-minute WidgetKit refresh.
- Cross-platform support.
- Notifications, historical charts, automatic updates, or App Store distribution before source accuracy is proven.

## 9. Success criteria for the first proven slice

The first slice is complete when:

1. A signed-in user can open a menu-bar panel and see fixtures for multiple independent constraints.
2. Used, remaining, reset, stale, unavailable, and unsupported states are rendered correctly and accessibly.
3. At least one documented live source can refresh through an adapter without exposing its credential.
4. Disconnecting or rejecting that source leaves the last observation visibly stale rather than replacing it with zero.
5. Tests prove that differently scoped windows cannot be combined accidentally.
6. No credential or raw authorization value appears in source control, logs, or the snapshot cache.

## 10. Open decisions

- Minimum supported macOS version.
- Whether the first live adapter should be Codex subscription usage or an organization Usage API.
- Whether API Admin-key support belongs in the first public build given its privilege level.
- Whether local history is needed before WidgetKit or notifications.
- Distribution through the Mac App Store, notarized direct download, or both.
- Product name and bundle identifier.

## 11. Local Codex vertical slice

The repository now includes a macOS 14 SwiftUI application with a `MenuBarExtra`, a resizable dashboard window, and one shared `UsageStore`. Live mode launches the configured absolute Codex executable directly as `app-server --stdio`; Codex continues to own authentication.

Build and test from a cold worktree:

```sh
make check
```

All build products are generated under ignored `.build/`; run `make help` for every supported build, diagnostic, live-test, package, and clean workflow.

Run the signed-in local Codex source and open the dashboard immediately:

```sh
APP="$(xcodebuild -project UsageMenu.xcodeproj -scheme UsageMenu \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData -showBuildSettings \
  | awk -F ' = ' '/TARGET_BUILD_DIR/{dir=$2} /WRAPPER_NAME/{name=$2} END{print dir "/" name}')"
open -na "$APP" --args --open-dashboard \
  --codex-path /absolute/path/to/codex
```

The exact DerivedData path can be obtained without assuming its hash:

```sh
APP="$(xcodebuild -project UsageMenu.xcodeproj -scheme UsageMenu \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData -showBuildSettings \
  | awk -F ' = ' '/TARGET_BUILD_DIR/{dir=$2} /WRAPPER_NAME/{name=$2} END{print dir "/" name}')"
open -na "$APP" --args --open-dashboard
```

Use explicit, visibly labelled deterministic fixture data only when requested:

```sh
open -na "$APP" --args --open-dashboard --fixture
```

Run the opt-in protocol smoke test against the installed signed-in Codex app-server:

```sh
CODEX_PATH=/absolute/path/to/codex make live-test
```

Override the executable for a normal app launch with `--codex-path /absolute/path/to/codex` or `USAGE_MENU_CODEX_PATH`. A failed live source remains unavailable, or marks exact prior observations stale; it never falls back to fixture values.

## 12. Refresh and redacted diagnostics

The refresh lifecycle is shared, activation-aware, and single-flight:

- The shared `UsageStore` is triggered by the first `.task` on either the menu or dashboard surface. The second surface observes the same store and does not start a second startup refresh.
- macOS application activation (`NSApplication.didBecomeActiveNotification`) requests that same store refresh. Activation bursts replace one pending debounced request, and the store's single-flight boundary prevents an activation from overlapping a manual or startup request.
- A manual refresh button calls the same `UsageStore.refresh()` method. While a refresh is active, additional startup, activation, or manual calls return immediately (`isRefreshing`), so one Codex child and one Anthropic request are in flight at most. Existing observations are labelled stale with “Refresh in progress” until that attempt succeeds; a success restores current readings.
- Codex and Anthropic acquisition begin concurrently. Codex starts one app-server child per fetch and stops it in `defer`; cancellation and application termination call both source `cancel()` methods.
- There is no timer or polling loop in this release, and therefore no refresh interval today. The configurable five-to-fifteen-minute polling described above remains planned, not implemented.
- On Codex failure, each prior observation remains visible as `stale` without reset expiry filtering. Anthropic transient failures retain only observations whose reset is still in the future; expired observations become unavailable. Auth-required and unknown-response cases remain their explicit statuses.

Run the native, redacted diagnostic chokepoint from the repository root:

```sh
make diagnose                  # live native adapters
make diagnose-fixture          # deterministic semantic fixture
```

The command emits provider, normalized window identity/title, interval, used and remaining signs, reset, observation/freshness, status, and source-field provenance. It emits explicit unavailable rows for expected absent base/session and weekly windows. It never emits account references, credentials, authorization, or raw responses, and does not use Node or Quota Axi at runtime.

## 13. Authentication persistence boundary

The app does not persist, restore, refresh, or copy either provider's CLI credential. Codex authentication remains entirely behind the provider-owned `app-server`; Anthropic's local-only exception reads the existing Claude Code credential into request memory and sends it only to Anthropic's provider-owned usage host. Usage Menu persists only the non-secret Codex executable preference.

The auth-persistence probe uses redacted metadata only: it checks whether a bounded local Claude credential record has a recognized shape and, when the provider record supplies expiry metadata, whether it is expired. It does not query Keychain when that file satisfies the read, and it never prints a credential, authorization value, or private response. The 2026-08-14 probe found a bounded recognized record with valid expiry metadata, so it ruled out an app persistence/restoration failure and a currently expired recorded credential; it did not send a live usage request.

There is no sanctioned Usage Menu renewal protocol. An expired provider-recorded Anthropic credential is classified directly as `auth-required` before any request; the user must complete the provider's own interactive login. A provider 401/403 remains `auth-required`. This preserves the provider boundary rather than retrying, refreshing, or simulating persistence, and never turns an auth failure into zero or current data.

## 14. Planned sequencing

Architecture decisions, implementation tasks, and delivery milestones beyond this local vertical slice will be planned after the requirements have been reviewed against supported provider interfaces.
