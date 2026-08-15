import SwiftUI
import XCTest
@testable import UsageMenu

@MainActor
final class SharedSurfaceIntegrationTests: XCTestCase {
    func testCompactMenuAndDashboardResolveOneStoreAndExactPresentationIdentity() async {
        let store = fixtureStore()
        let compact = CompactMenuView(store: store)
        let dashboard = DashboardView(store: store)
        _ = compact
        _ = dashboard

        await store.refresh()
        let compactSnapshot = UsagePresentation.snapshot(from: store)
        let dashboardSnapshot = UsagePresentation.snapshot(from: store)

        XCTAssertEqual(compactSnapshot, dashboardSnapshot)
        XCTAssertEqual(compactSnapshot.compactMap(\.observationID).count, 4)
        XCTAssertEqual(compactSnapshot.compactMap(\.observedAt).count, 4)
        XCTAssertEqual(Set(compactSnapshot.compactMap(\.observedAt)).count, 1)
        XCTAssertEqual(store.mode, .fixture)
        XCTAssertTrue(store.sourceLabel.lowercased().contains("fixture"))
        XCTAssertFalse(store.instanceIdentifier.uuidString.isEmpty)
    }

    func testOpenAIFirstAnthropicSecondAndStateTextRemainNonColorSemantics() async {
        let store = fixtureStore()
        await store.refresh()

        XCTAssertEqual(store.readings.map(\.provider), [.openAI, .openAI, .anthropic, .anthropic])
        XCTAssertEqual(store.readings.map { $0.state.statusName }, ["current", "current", "current", "current"])
        XCTAssertEqual(store.session.observation?.remaining, 18)
        XCTAssertEqual(store.weekly.observation?.remaining, 64)
        XCTAssertEqual(store.anthropicReadings.first?.state.observation?.remaining, 87)
    }

    func testAnthropicAccessibilityDisclosesValueResetFreshnessStateAndUndocumentedSource() async {
        let store = fixtureStore()
        await store.refresh()
        let labels = store.anthropicReadings.map { UsageAccessibility.label(for: $0).lowercased() }

        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            XCTAssertTrue(label.contains("anthropic"))
            XCTAssertTrue(label.contains("remaining"))
            XCTAssertTrue(label.contains("reset"))
            XCTAssertTrue(label.contains("observed"))
            XCTAssertTrue(label.contains("state current"))
            XCTAssertFalse(label.contains("local claude code"))
            XCTAssertFalse(label.contains("undocumented provider-owned"))
        }
        for reading in store.anthropicReadings {
            let details = UsageAccessibility.sourceSummary(for: reading).lowercased()
            XCTAssertTrue(details.contains("local claude code") || details.contains("unavailable"))
        }
    }

    func testClaudeAuthRecoveryOffersTerminalGuidanceAndHonestLaunchFailure() {
        let readings = [anthropicStatus(.authRequired(.anthropicAuthRequired))]
        XCTAssertTrue(ClaudeLoginRecovery.isRequired(for: readings))
        XCTAssertEqual(ClaudeLoginRecovery.guidance, "Open Terminal and run: claude auth login")
        XCTAssertEqual(ClaudeLoginRecovery.openTerminal(using: { _ in true }), "Terminal opened. Open Terminal and run: claude auth login")
        XCTAssertEqual(ClaudeLoginRecovery.openTerminal(using: { _ in false }), "Could not open Terminal. Open Terminal and run: claude auth login")
        XCTAssertFalse(ClaudeLoginRecovery.isRequired(for: [anthropicStatus(.unavailable(.anthropicNetworkUnavailable))]))
    }

    func testSourceDetailsAreHiddenOnlyFromCompactMenu() {
        XCTAssertFalse(SurfaceDetailsPolicy.showsSourceDetails(compact: true))
        XCTAssertTrue(SurfaceDetailsPolicy.showsSourceDetails(compact: false))

        let authReading = anthropicStatus(.authRequired(.anthropicAuthRequired))
        let accessibility = UsageAccessibility.label(for: authReading).lowercased()
        XCTAssertTrue(accessibility.contains("sign-in required"))
        XCTAssertTrue(accessibility.contains("state auth-required"))
    }

    func testDashboardAndMenuViewsHaveNoIndependentAcquisitionState() {
        let store = fixtureStore()
        let menu = CompactMenuView(store: store)
        let dashboard = DashboardView(store: store)

        XCTAssertEqual(menu.resolvedStoreIdentifier, store.instanceIdentifier)
        XCTAssertEqual(dashboard.resolvedStoreIdentifier, store.instanceIdentifier)
        XCTAssertEqual(menu.resolvedStoreIdentifier, dashboard.resolvedStoreIdentifier)
    }

    func testApprovedHierarchyUsesWeeklyFirstAndConditionalFiveHourVocabulary() async {
        let store = fixtureStore()
        await store.refresh()

        let openAI = UsageAccessibility.visibleReadings(from: store.readings.filter { $0.provider == .openAI })
        let anthropic = UsageAccessibility.visibleReadings(from: store.readings.filter { $0.provider == .anthropic })

        XCTAssertEqual(openAI.map { UsageAccessibility.windowTitle(for: $0) }, ["Weekly", "5-hour"])
        XCTAssertEqual(anthropic.map { UsageAccessibility.windowTitle(for: $0) }, ["Weekly", "5-hour"])
        XCTAssertEqual(store.readings.map(\.provider), [.openAI, .openAI, .anthropic, .anthropic])
    }

    func testReturnedFiveHourWindowIsShownButMissingWindowIsHiddenFromDefaultReadings() {
        let fixture = ReadingFixtures.observation
        let weeklyObservation = UsageObservation(
            scope: ObservationScope(
                provider: fixture.scope.provider,
                accountReference: fixture.scope.accountReference,
                productSurface: fixture.scope.productSurface,
                resource: "codex-weekly",
                unit: fixture.scope.unit,
                intervalSeconds: 604_800,
                provenance: fixture.scope.provenance
            ),
            kind: fixture.kind,
            used: fixture.used,
            remaining: fixture.remaining,
            limit: fixture.limit,
            resetAt: fixture.resetAt,
            observedAt: fixture.observedAt,
            confidence: fixture.confidence
        )
        let weekly = UsageReading(
            id: .codexWeekly,
            provider: .openAI,
            title: "Codex weekly",
            scopeDescription: "Consumer · weekly rate-limit window",
            state: .current(weeklyObservation)
        )
        let missingFiveHour = UsageReading(
            id: .codexSession,
            provider: .openAI,
            title: "Codex session",
            scopeDescription: "Consumer · short rate-limit window",
            state: .unavailable(.missingSupportedField)
        )

        let visible = UsageAccessibility.visibleReadings(from: [missingFiveHour, weekly])
        XCTAssertEqual(visible.map(\.id), [.codexWeekly])
        XCTAssertFalse(visible.contains { UsageAccessibility.isFiveHour($0) })
    }

    func testTechnicalEvidenceIsNotInDefaultAccessibilityLabel() {
        let reading = UsageReading(
            id: .codexWeekly,
            provider: .openAI,
            title: "Codex weekly",
            scopeDescription: "Consumer · weekly rate-limit window",
            state: .current(ReadingFixtures.observation)
        )

        let label = UsageAccessibility.label(for: reading)
        XCTAssertTrue(label.contains("remaining"))
        XCTAssertTrue(label.contains("reset"))
        XCTAssertTrue(label.contains("observed"))
        XCTAssertFalse(label.contains(ReadingFixtures.observation.id))
        XCTAssertFalse(label.contains(ReadingFixtures.observation.scope.provenance))
    }

    func testCompactMenuActionsUseDistinctApprovedDestinations() {
        XCTAssertEqual(CompactMenuAction.settings.destination, .settings)
        XCTAssertEqual(CompactMenuAction.openDashboard.destination, .dashboard)
        XCTAssertNotEqual(
            CompactMenuAction.settings.destination,
            CompactMenuAction.openDashboard.destination
        )
    }

    /// The Dock icon is transient by decision: present while a window is up, gone when the last
    /// one closes. The off-by-one is the risk — `willClose` fires while the closing window is
    /// still counted — so it is pinned rather than trusted.
    func testDockIconIsHeldOnlyWhileAWindowOtherThanTheClosingOneRemains() {
        XCTAssertFalse(
            WindowPresentation.shouldKeepDockIcon(focusableWindowCountIncludingClosing: 1),
            "the last window closing must return the app to accessory, or the Dock icon strands"
        )
        XCTAssertTrue(
            WindowPresentation.shouldKeepDockIcon(focusableWindowCountIncludingClosing: 2),
            "a second open window must keep the Dock icon, or it vanishes while a window is up"
        )
        XCTAssertFalse(WindowPresentation.shouldKeepDockIcon(focusableWindowCountIncludingClosing: 0))
    }

    /// Settings is Option A: only controls that do something. The sentences it shows about a
    /// missing executable are the product's honesty rule written into the UI, so they are pinned
    /// here rather than trusted to a visual glance.
    func testSettingsNamesTheUnresolvedCodexStateWithoutEverImplyingAZero() {
        let notFound = CodexExecutableDiscovery.Outcome(path: nil, origin: nil)
        XCTAssertEqual(SettingsPresentation.codexStatusLabel(for: notFound), "Not found")
        XCTAssertFalse(SettingsPresentation.codexIsResolved(notFound))
        XCTAssertEqual(SettingsPresentation.codexPathText(for: notFound), "No executable")

        let consequence = try? XCTUnwrap(SettingsPresentation.codexConsequenceText(for: notFound))
        let text = consequence ?? ""
        XCTAssertTrue(text.contains("stay unavailable"))
        XCTAssertTrue(text.contains("never shown as zero or current"))
        XCTAssertTrue(text.contains("found nothing"))
    }

    /// The two failure states must stay distinguishable in the UI, not just in the domain — a
    /// path someone set that has gone is a different problem from a Mac with no codex at all.
    func testSettingsDistinguishesAGoneConfiguredPathFromNothingFoundAnywhere() {
        let gone = CodexExecutableDiscovery.Outcome(path: nil, origin: .userPreference)
        let missing = CodexExecutableDiscovery.Outcome(path: nil, origin: nil)

        XCTAssertEqual(SettingsPresentation.codexStatusLabel(for: gone), "Path is gone")
        XCTAssertNotEqual(
            SettingsPresentation.codexStatusLabel(for: gone),
            SettingsPresentation.codexStatusLabel(for: missing)
        )
        XCTAssertTrue(
            (SettingsPresentation.codexConsequenceText(for: gone) ?? "")
                .contains("no longer exists")
        )
    }

    func testSettingsReportsAResolvedExecutableAndItsOriginWithNoConsequenceWarning() {
        let resolved = CodexExecutableDiscovery.Outcome(
            path: "/opt/homebrew/bin/codex", origin: .loginShell)
        XCTAssertEqual(SettingsPresentation.codexStatusLabel(for: resolved), "Resolved")
        XCTAssertTrue(SettingsPresentation.codexIsResolved(resolved))
        XCTAssertEqual(SettingsPresentation.codexPathText(for: resolved), "/opt/homebrew/bin/codex")
        XCTAssertEqual(
            SettingsPresentation.codexOriginText(for: resolved),
            "Found by asking your login shell"
        )
        XCTAssertNil(
            SettingsPresentation.codexConsequenceText(for: resolved),
            "a resolved executable must not carry a failure warning"
        )
    }

    /// "Not found" is only honest if it can be checked, so the panel lists what was tried and
    /// that list must actually match the order discovery uses.
    func testSettingsListsTheLocationsDiscoveryActuallySearched() {
        let listed = SettingsPresentation.searchedLocations(homeDirectory: "/home")
        XCTAssertTrue(listed.contains("Your PATH"))
        XCTAssertTrue(listed.contains("Your login shell"))
        for directory in CodexExecutableDiscovery.knownDirectories(homeDirectory: "/home") {
            XCTAssertTrue(
                listed.contains(directory + "/codex"),
                "settings claims a search it does not list: \(directory)"
            )
        }
    }

    /// Fixture mode has no executable to resolve, and saying "Not found" there would be a small
    /// lie of its own.
    func testSettingsDoesNotReportAFailureWhenThereIsNoExecutableToResolve() {
        XCTAssertEqual(SettingsPresentation.codexStatusLabel(for: nil), "Not applicable")
        XCTAssertNil(SettingsPresentation.codexConsequenceText(for: nil))
        XCTAssertFalse(SettingsPresentation.codexPathText(for: nil).isEmpty)
    }

    func testCompactWidgetPresentationBoundaryEmitsOpenThenAcquisitionAttempt() async throws {
        var events: [AutomaticRefreshEvent] = []
        let store = UsageStore(
            codexSource: FixtureCodexSource(),
            anthropicSource: FixtureAnthropicSource(),
            mode: .fixture,
            activationDebounceNanoseconds: 0,
            recordAutomaticRefreshEvent: { events.append($0) }
        )

        CompactWidgetPresentationBoundary.appeared(store: store)
        for _ in 0..<50 where events.count < 2 { await Task.yield() }

        XCTAssertEqual(events, [.widgetOpened, .acquisitionAttempt])
    }

    /// This pins the actual MenuBarExtra content to the production presentation boundary. It
    /// deliberately fails if somebody substitutes the app-activation path, which is unreliable
    /// for an LSUIElement status app.
    func testMenuBarExtraCompactContentWiresOnAppearToPresentationBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(contentsOf: repositoryRoot.appendingPathComponent("UsageMenu/App/UsageMenuApp.swift"))
        let compactContent = try XCTUnwrap(appSource.components(separatedBy: "MenuBarExtra {").dropFirst().first)
        let contentBeforeLabel = try XCTUnwrap(compactContent.components(separatedBy: "} label:").first)

        XCTAssertTrue(contentBeforeLabel.contains(".onAppear { CompactWidgetPresentationBoundary.appeared(store: store) }"))
        XCTAssertFalse(contentBeforeLabel.contains("refreshAfterActivation"))
    }

    private func anthropicStatus(_ state: ReadingState) -> UsageReading {
        UsageReading(
            id: .anthropicStatus,
            provider: .anthropic,
            title: "Claude subscription quota",
            scopeDescription: "Consumer · local Claude Code",
            state: state
        )
    }

    private func fixtureStore() -> UsageStore {
        UsageStore(
            codexSource: FixtureCodexSource(),
            anthropicSource: FixtureAnthropicSource(),
            mode: .fixture
        )
    }
}
