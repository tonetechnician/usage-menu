import Foundation
import XCTest
@testable import UsageMenu

@MainActor
final class UsageStoreTests: XCTestCase {
    func testCodexSuccessThenFailurePreservesExactObservationsAsStale() async {
        let snapshot = await fixtureCodexSnapshot()
        let codex = ScriptedCodexSource(results: [.success(snapshot), .failure(RedactedIssue.processExited)])
        let store = UsageStore(codexSource: codex, anthropicSource: FixtureAnthropicSource(), mode: .live)

        await store.refresh()
        let priorSession = store.session.observation
        let priorWeekly = store.weekly.observation
        await store.refresh()

        guard case .stale(let staleSession, .processExited) = store.session,
              case .stale(let staleWeekly, .processExited) = store.weekly else {
            return XCTFail("Prior values must become explicitly stale")
        }
        XCTAssertEqual(staleSession, priorSession)
        XCTAssertEqual(staleWeekly, priorWeekly)
    }

    func testCodexFailureBeforeSuccessIsUnavailableNotZero() async {
        let store = UsageStore(
            codexSource: ScriptedCodexSource(results: [.failure(RedactedIssue.executableMissing)]),
            anthropicSource: FixtureAnthropicSource(),
            mode: .live
        )
        await store.refresh()
        XCTAssertEqual(store.session, .unavailable(.executableMissing))
        XCTAssertEqual(store.weekly, .unavailable(.executableMissing))
        XCTAssertNil(store.session.observation)
    }

    func testMissingSupportedCodexWindowIsUnknownAndDoesNotBorrowOtherWindow() async {
        let complete = await fixtureCodexSnapshot()
        let store = UsageStore(
            codexSource: ScriptedCodexSource(results: [.success(CodexSnapshot(session: complete.session, weekly: nil))]),
            anthropicSource: FixtureAnthropicSource(),
            mode: .live
        )
        await store.refresh()
        XCTAssertEqual(store.session.observation?.id, complete.session?.id)
        guard case .unknown = store.weekly else { return XCTFail("Missing weekly field must be unknown") }
        XCTAssertNil(store.weekly.observation)
    }

    func testAnthropicSuccessThenTransientFailurePreservesExactSanitizedIDsAsStale() async throws {
        let snapshot = try anthropicSnapshot(sessionReset: 1_900_010_000, weeklyReset: 1_900_020_000)
        let anthropic = ScriptedAnthropicSource(results: [
            .success(snapshot), .failure(AnthropicSourceFailure(.anthropicServerUnavailable))
        ])
        let store = UsageStore(
            codexSource: ScriptedCodexSource(results: [.success(await fixtureCodexSnapshot()), .success(await fixtureCodexSnapshot())]),
            anthropicSource: anthropic,
            mode: .live,
            now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )

        await store.refresh()
        let exactPrior = store.anthropicReadings.map { $0.state.observation }
        await store.refresh()

        XCTAssertEqual(store.anthropicReadings.map { $0.state.observation }, exactPrior)
        XCTAssertEqual(store.anthropicReadings.map { $0.state.statusName }, ["stale", "stale"])
        XCTAssertEqual(
            store.anthropicReadings.compactMap { $0.state.observation?.id },
            exactPrior.compactMap { $0?.id }
        )
    }

    func testAnthropicStaleExpiryRemovesActionableHeadroom() async throws {
        let snapshot = try anthropicSnapshot(sessionReset: 1_899_999_999, weeklyReset: 1_900_020_000)
        let anthropic = ScriptedAnthropicSource(results: [
            .success(snapshot), .failure(AnthropicSourceFailure(.anthropicNetworkUnavailable))
        ])
        let codexSnapshot = await fixtureCodexSnapshot()
        let store = UsageStore(
            codexSource: ScriptedCodexSource(results: [.success(codexSnapshot), .success(codexSnapshot)]),
            anthropicSource: anthropic,
            mode: .live,
            now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.anthropicReadings.count, 1)
        XCTAssertEqual(store.anthropicReadings.first?.id, .anthropic("seven_day"))
        XCTAssertEqual(store.anthropicReadings.first?.state.statusName, "stale")
    }

    func testAnthropicAuthFailureRetiresPriorQuotaInsteadOfShowingStale() async throws {
        let snapshot = try anthropicSnapshot(sessionReset: 1_900_010_000, weeklyReset: 1_900_020_000)
        let anthropic = ScriptedAnthropicSource(results: [
            .success(snapshot), .failure(AnthropicSourceFailure(.anthropicAuthRequired))
        ])
        let codexSnapshot = await fixtureCodexSnapshot()
        let store = UsageStore(
            codexSource: ScriptedCodexSource(results: [.success(codexSnapshot), .success(codexSnapshot)]),
            anthropicSource: anthropic,
            mode: .live
        )
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.anthropicReadings.map(\.id), [.anthropicStatus])
        XCTAssertEqual(store.anthropicReadings.first?.state, .authRequired(.anthropicAuthRequired))
    }

    func testProviderFailuresRemainIsolatedAndOpenAIAlwaysComesFirst() async throws {
        let codexSnapshot = await fixtureCodexSnapshot()
        let anthropicSnapshot = try anthropicSnapshot(sessionReset: 1_900_010_000, weeklyReset: 1_900_020_000)
        let anthropicFailureStore = UsageStore(
            codexSource: ScriptedCodexSource(results: [.success(codexSnapshot)]),
            anthropicSource: ScriptedAnthropicSource(results: [.failure(AnthropicSourceFailure(.anthropicTimeout))]),
            mode: .live
        )
        await anthropicFailureStore.refresh()
        XCTAssertEqual(anthropicFailureStore.session.observation?.id, codexSnapshot.session?.id)
        XCTAssertEqual(anthropicFailureStore.readings.prefix(2).map(\.provider), [.openAI, .openAI])
        XCTAssertEqual(anthropicFailureStore.readings.last?.provider, .anthropic)

        let codexFailureStore = UsageStore(
            codexSource: ScriptedCodexSource(results: [.failure(RedactedIssue.processExited)]),
            anthropicSource: ScriptedAnthropicSource(results: [.success(anthropicSnapshot)]),
            mode: .live
        )
        await codexFailureStore.refresh()
        XCTAssertEqual(codexFailureStore.session, .unavailable(.processExited))
        XCTAssertTrue(codexFailureStore.anthropicReadings.allSatisfy { $0.state.statusName == "current" })
    }

    func testManualRefreshIsSingleFlightForBothSources() async {
        let codex = ScriptedCodexSource(results: [.success(await fixtureCodexSnapshot())], delayNanoseconds: 150_000_000)
        let anthropic = ScriptedAnthropicSource(results: [.success(try! await FixtureAnthropicSource().fetch())], delayNanoseconds: 150_000_000)
        let store = UsageStore(codexSource: codex, anthropicSource: anthropic, mode: .fixture)

        let first = Task { await store.refresh() }
        await Task.yield()
        let second = Task { await store.refresh() }
        _ = await (first.value, second.value)

        XCTAssertEqual(codex.callCount, 1)
        XCTAssertEqual(anthropic.callCount, 1)
        XCTAssertEqual(codex.maximumConcurrentCalls, 1)
        XCTAssertEqual(anthropic.maximumConcurrentCalls, 1)
    }

    func testActivationBurstDebouncesToOneRefreshAndMarksPriorReadingsNonCurrentUntilSuccess() async throws {
        let initialCodex = await fixtureCodexSnapshot()
        let initialAnthropic = try await FixtureAnthropicSource().fetch()
        let codex = ScriptedCodexSource(
            results: [.success(initialCodex), .success(initialCodex)],
            delayNanoseconds: 150_000_000
        )
        let anthropic = ScriptedAnthropicSource(
            results: [.success(initialAnthropic), .success(initialAnthropic)],
            delayNanoseconds: 150_000_000
        )
        let store = UsageStore(
            codexSource: codex,
            anthropicSource: anthropic,
            mode: .fixture,
            activationDebounceNanoseconds: 0
        )

        await store.refresh()
        store.refreshAfterActivation()
        store.refreshAfterActivation()
        store.refreshAfterActivation()
        for _ in 0..<20 where codex.callCount < 2 || anthropic.callCount < 2 { await Task.yield() }

        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(store.session.statusName, "stale")
        XCTAssertEqual(store.weekly.statusName, "stale")
        XCTAssertTrue(store.anthropicReadings.allSatisfy { $0.state.statusName == "stale" })
        XCTAssertEqual(store.session.observation, initialCodex.session)
        XCTAssertEqual(codex.callCount, 2, "one initial and one coalesced activation fetch")
        XCTAssertEqual(anthropic.callCount, 2, "one initial and one coalesced activation fetch")

        while store.isRefreshing { await Task.yield() }
        XCTAssertEqual(store.session.statusName, "current")
        XCTAssertEqual(store.weekly.statusName, "current")
        XCTAssertTrue(store.anthropicReadings.allSatisfy { $0.state.statusName == "current" })
        XCTAssertEqual(codex.maximumConcurrentCalls, 1)
        XCTAssertEqual(anthropic.maximumConcurrentCalls, 1)
    }

    func testActivationFailurePreservesOnlyProviderSpecificPriorObservationsAsStale() async throws {
        let codexSnapshot = await fixtureCodexSnapshot()
        let anthropicSnapshot = try anthropicSnapshot(sessionReset: 1_900_010_000, weeklyReset: 1_900_020_000)
        let store = UsageStore(
            codexSource: ScriptedCodexSource(results: [.success(codexSnapshot), .failure(RedactedIssue.processExited)]),
            anthropicSource: ScriptedAnthropicSource(results: [.success(anthropicSnapshot), .failure(AnthropicSourceFailure(.anthropicTimeout))]),
            mode: .live,
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            activationDebounceNanoseconds: 0
        )
        await store.refresh()
        let codexPrior = store.session.observation
        let anthropicPrior = store.anthropicReadings.map { $0.state.observation }

        store.refreshAfterActivation()
        while store.isRefreshing == false { await Task.yield() }
        XCTAssertEqual(store.session.observation, codexPrior)
        XCTAssertTrue(store.anthropicReadings.allSatisfy { $0.state.statusName == "stale" })
        while store.isRefreshing { await Task.yield() }

        guard case .stale(let observation, .processExited) = store.session else {
            return XCTFail("Codex activation failure must retain its exact prior reading as stale")
        }
        XCTAssertEqual(observation, codexPrior)
        XCTAssertEqual(store.anthropicReadings.map { $0.state.observation }, anthropicPrior)
        XCTAssertTrue(store.anthropicReadings.allSatisfy { $0.state.statusName == "stale" })
    }

    func testSharedStartupTriggerIsOneShotAndPollingIsAbsent() async {
        let codex = ScriptedCodexSource(results: [.success(await fixtureCodexSnapshot())])
        let anthropic = ScriptedAnthropicSource(results: [.success(try! await FixtureAnthropicSource().fetch())])
        let store = UsageStore(codexSource: codex, anthropicSource: anthropic, mode: .fixture)

        await store.refreshOnStartupIfNeeded()
        await store.refreshOnStartupIfNeeded()

        XCTAssertEqual(codex.callCount, 1)
        XCTAssertEqual(anthropic.callCount, 1)
        XCTAssertNil(UsageStore.automaticRefreshInterval)
        XCTAssertNotNil(store.lastAttemptAt)
    }

    func testProviderFetchesStartConcurrentlyAndCancellationFansOut() async {
        let codex = ScriptedCodexSource(results: [.success(await fixtureCodexSnapshot())], delayNanoseconds: 100_000_000)
        let anthropic = ScriptedAnthropicSource(results: [.success(try! await FixtureAnthropicSource().fetch())], delayNanoseconds: 100_000_000)
        let store = UsageStore(codexSource: codex, anthropicSource: anthropic, mode: .fixture)

        let refresh = Task { await store.refresh() }
        for _ in 0..<20 where codex.callCount == 0 || anthropic.callCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(codex.callCount, 1)
        XCTAssertEqual(anthropic.callCount, 1)
        store.cancel()
        await refresh.value
        XCTAssertEqual(codex.cancelCallCount, 1)
        XCTAssertEqual(anthropic.cancelCallCount, 1)
    }

    func testStableIdentityChangesForEveryScopeDimension() {
        let base = ReadingFixtures.observation
        let scopes = [
            base.scope,
            scope(from: base.scope, provider: .anthropic),
            scope(from: base.scope, account: "acct_other"),
            scope(from: base.scope, surface: .organization),
            scope(from: base.scope, resource: "other-resource"),
            scope(from: base.scope, unit: .requests),
            scope(from: base.scope, interval: 60),
            scope(from: base.scope, provenance: "other:field")
        ]
        let observations = scopes.map {
            UsageObservation(scope: $0, kind: .rateLimit, observedAt: base.observedAt, confidence: .authoritative)
        }
        XCTAssertEqual(Set(observations.map(\.id)).count, observations.count)
        for scope in scopes.dropFirst() { XCTAssertFalse(base.scope.canDerive(with: scope)) }
    }

    func testExplicitFixturesCoverAllTruthfulPresentationStates() {
        XCTAssertEqual(ReadingFixtures.current.statusName, "current")
        XCTAssertEqual(ReadingFixtures.stale.statusName, "stale")
        XCTAssertEqual(ReadingFixtures.unavailable.statusName, "unavailable")
        XCTAssertEqual(ReadingFixtures.authRequired.statusName, "auth-required")
        XCTAssertEqual(ReadingFixtures.unsupported.statusName, "unsupported")
        XCTAssertEqual(ReadingFixtures.unknown.statusName, "unknown")
        XCTAssertNil(ReadingFixtures.authRequired.observation)
    }

    private func fixtureCodexSnapshot() async -> CodexSnapshot {
        try! await FixtureCodexSource().fetch()
    }

    private func anthropicSnapshot(sessionReset: TimeInterval, weeklyReset: TimeInterval) throws -> AnthropicSnapshot {
        let data = try JSONSerialization.data(withJSONObject: [
            "five_hour": ["utilization": 20, "resets_at": iso(sessionReset)],
            "seven_day": ["utilization": 40, "resets_at": iso(weeklyReset)]
        ])
        return try AnthropicQuotaMapper.map(data: data, observedAt: Date(timeIntervalSince1970: 1_899_990_000))
    }

    private func iso(_ timestamp: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func scope(
        from base: ObservationScope,
        provider: Provider? = nil,
        account: String? = nil,
        surface: ProductSurface? = nil,
        resource: String? = nil,
        unit: ObservationUnit? = nil,
        interval: Int? = nil,
        provenance: String? = nil
    ) -> ObservationScope {
        ObservationScope(
            provider: provider ?? base.provider,
            accountReference: account ?? base.accountReference,
            productSurface: surface ?? base.productSurface,
            resource: resource ?? base.resource,
            unit: unit ?? base.unit,
            intervalSeconds: interval ?? base.intervalSeconds,
            provenance: provenance ?? base.provenance
        )
    }
}

private final class ScriptedCodexSource: CodexUsageSource {
    private let lock = NSLock()
    private var results: [Result<CodexSnapshot, Error>]
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var cancelCallCount = 0
    private var concurrentCalls = 0

    init(results: [Result<CodexSnapshot, Error>], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    func fetch() async throws -> CodexSnapshot {
        let result: Result<CodexSnapshot, Error> = lock.withLock {
            callCount += 1
            concurrentCalls += 1
            maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
            return results.isEmpty ? .failure(RedactedIssue.protocolEOF) : results.removeFirst()
        }
        defer { lock.withLock { concurrentCalls -= 1 } }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return try result.get()
    }

    func cancel() {
        lock.withLock { cancelCallCount += 1 }
    }
}

private final class ScriptedAnthropicSource: AnthropicUsageSource {
    private let lock = NSLock()
    private var results: [Result<AnthropicSnapshot, Error>]
    private let delayNanoseconds: UInt64
    private(set) var cancelCallCount = 0
    private(set) var callCount = 0
    private(set) var maximumConcurrentCalls = 0
    private var concurrentCalls = 0

    init(results: [Result<AnthropicSnapshot, Error>], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    func fetch() async throws -> AnthropicSnapshot {
        let result: Result<AnthropicSnapshot, Error> = lock.withLock {
            callCount += 1
            concurrentCalls += 1
            maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
            return results.isEmpty ? .failure(AnthropicSourceFailure(.anthropicNetworkUnavailable)) : results.removeFirst()
        }
        defer { lock.withLock { concurrentCalls -= 1 } }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return try result.get()
    }

    func cancel() {
        lock.withLock { cancelCallCount += 1 }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
