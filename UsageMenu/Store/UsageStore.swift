import Combine
import Foundation

enum AutomaticRefreshEvent: String {
    case widgetOpened = "widget_opened"
    case acquisitionAttempt = "acquisition_attempt"
}

@MainActor
final class UsageStore: ObservableObject {
    let instanceIdentifier = UUID()
    let mode: AcquisitionMode
    let sourceLabel: String

    @Published private(set) var session: ReadingState = .unavailable(.notRefreshed)
    @Published private(set) var weekly: ReadingState = .unavailable(.notRefreshed)
    @Published private(set) var anthropicReadings: [UsageReading]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastAttemptAt: Date?

    /// How the Codex executable resolved, published so Settings can state it rather than
    /// leaving the user to guess why a provider is silent. `nil` in fixture mode, where there
    /// is no executable to resolve and pretending otherwise would be its own small lie.
    @Published private(set) var codexResolution: CodexExecutableDiscovery.Outcome?

    private var codexSource: CodexUsageSource
    private let anthropicSource: AnthropicUsageSource
    private let now: () -> Date
    private let activationDebounceNanoseconds: UInt64
    private var automaticRefreshTask: Task<Void, Never>?
    private let recordAutomaticRefreshEvent: (AutomaticRefreshEvent) -> Void
    /// Supplied by the app so that changing the path rebuilds the live source — and so the
    /// app can re-take lifecycle ownership of the replacement, which only it can do.
    private let rebuildCodexSource: ((CodexExecutableDiscovery.Outcome) -> CodexUsageSource)?

    init(
        codexSource: CodexUsageSource,
        anthropicSource: AnthropicUsageSource,
        mode: AcquisitionMode,
        now: @escaping () -> Date = Date.init,
        activationDebounceNanoseconds: UInt64 = 300_000_000,
        codexResolution: CodexExecutableDiscovery.Outcome? = nil,
        rebuildCodexSource: ((CodexExecutableDiscovery.Outcome) -> CodexUsageSource)? = nil,
        recordAutomaticRefreshEvent: @escaping (AutomaticRefreshEvent) -> Void = { _ in }
    ) {
        self.codexResolution = codexResolution
        self.rebuildCodexSource = rebuildCodexSource
        self.codexSource = codexSource
        self.anthropicSource = anthropicSource
        self.mode = mode
        self.now = now
        self.activationDebounceNanoseconds = activationDebounceNanoseconds
        self.recordAutomaticRefreshEvent = recordAutomaticRefreshEvent
        self.sourceLabel = mode == .fixture
            ? "Fixture · explicit Codex and Claude schemas"
            : "Live · local Codex + local Claude Code session"
        self.anthropicReadings = [Self.anthropicStatus(.unavailable(.notRefreshed))]
    }

    var readings: [UsageReading] {
        [
            UsageReading(
                id: .codexSession,
                provider: .openAI,
                title: "Codex session",
                scopeDescription: "Consumer · short rate-limit window",
                state: session
            ),
            UsageReading(
                id: .codexWeekly,
                provider: .openAI,
                title: "Codex weekly",
                scopeDescription: "Consumer · weekly rate-limit window",
                state: weekly
            )
        ] + anthropicReadings
    }

    /// Adopt an explicit executable, then re-read. The path is remembered, so a user who fixes
    /// this once does not fix it every launch.
    func chooseCodexExecutable(path: String) async {
        UsageMenuPreferences.codexExecutablePath = path
        await reresolveCodexExecutable()
    }

    /// Search again from scratch.
    ///
    /// This CLEARS the saved path first, and that is the whole point rather than a side effect:
    /// discovery deliberately stops at a user-named path instead of falling through to some other
    /// binary, so leaving a stale preference in place would make "Detect Again" re-find exactly
    /// the broken path it was pressed to escape.
    func redetectCodexExecutable() async {
        UsageMenuPreferences.codexExecutablePath = nil
        await reresolveCodexExecutable()
    }

    private func reresolveCodexExecutable() async {
        guard let rebuildCodexSource else { return }
        let outcome = CodexExecutableDiscovery.resolve(
            preference: UsageMenuPreferences.codexExecutablePath
        )
        codexResolution = outcome
        codexSource.cancel()
        codexSource = rebuildCodexSource(outcome)
        // The previous attempt's verdict must not survive a path change; refresh re-reads and
        // the readings speak for the NEW executable.
        lastAttemptAt = nil
        await refresh()
    }

    /// Shared by both SwiftUI surfaces. There is intentionally no timer or
    /// polling task; the first surface task performs the one startup refresh.
    func refreshOnStartupIfNeeded() async {
        guard lastAttemptAt == nil else { return }
        await refresh()
    }

    /// App activation is noisy, but a compact widget opening is the reliable boundary for an
    /// accessory app. Both requests deliberately use this one trailing-edge debounce and the
    /// same `refresh()` single-flight boundary.
    func refreshAfterActivation() {
        requestAutomaticRefresh()
    }

    func refreshAfterWidgetOpen() {
        recordAutomaticRefreshEvent(.widgetOpened)
        requestAutomaticRefresh()
    }

    private func requestAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { [weak self] in
            guard let self else { return }
            if self.activationDebounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: self.activationDebounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    static var automaticRefreshInterval: TimeInterval? { nil }

    func refresh() async {
        guard !isRefreshing else { return }
        recordAutomaticRefreshEvent(.acquisitionAttempt)
        markObservationsRefreshing()
        isRefreshing = true
        defer {
            isRefreshing = false
            lastAttemptAt = now()
        }

        async let codexResult = capture { try await codexSource.fetch() }
        async let anthropicResult = capture { try await anthropicSource.fetch() }
        let (resolvedCodex, resolvedAnthropic) = await (codexResult, anthropicResult)
        applyCodex(resolvedCodex)
        applyAnthropic(resolvedAnthropic)
    }

    func cancel() {
        automaticRefreshTask?.cancel()
        codexSource.cancel()
        anthropicSource.cancel()
    }

    private func markObservationsRefreshing() {
        session = nonCurrentDuringRefresh(session)
        weekly = nonCurrentDuringRefresh(weekly)
        anthropicReadings = anthropicReadings.map { reading in
            guard let observation = reading.state.observation else { return reading }
            var refreshing = reading
            refreshing.state = .stale(observation, .refreshInProgress)
            return refreshing
        }
    }

    private func nonCurrentDuringRefresh(_ state: ReadingState) -> ReadingState {
        guard let observation = state.observation else { return state }
        return .stale(observation, .refreshInProgress)
    }

    private func applyCodex(_ result: Result<CodexSnapshot, Error>) {
        switch result {
        case .success(let snapshot):
            session = snapshot.session.map(ReadingState.current)
                ?? .unknown(RedactedIssue.missingSupportedField.displayText)
            weekly = snapshot.weekly.map(ReadingState.current)
                ?? .unknown(RedactedIssue.missingSupportedField.displayText)
        case .failure(is CancellationError):
            applyCodexFailure(.cancelled)
        case .failure(let issue as RedactedIssue):
            applyCodexFailure(issue)
        case .failure:
            applyCodexFailure(.processLaunchFailed)
        }
    }

    private func applyAnthropic(_ result: Result<AnthropicSnapshot, Error>) {
        switch result {
        case .success(let snapshot):
            anthropicReadings = snapshot.readings.map {
                UsageReading(
                    id: $0.key,
                    provider: .anthropic,
                    title: $0.title,
                    scopeDescription: $0.scopeDescription,
                    state: .current($0.observation)
                )
            }
        case .failure(is CancellationError):
            applyAnthropicTransient(.cancelled)
        case .failure(let failure as AnthropicSourceFailure):
            switch failure.issue {
            case .anthropicCredentialsMissing, .anthropicCredentialsInvalid,
                 .anthropicCredentialsExpired, .anthropicKeychainDenied, .anthropicAuthRequired:
                anthropicReadings = [Self.anthropicStatus(.authRequired(failure.issue))]
            case .anthropicUnknownResponse:
                anthropicReadings = [Self.anthropicStatus(.unknown(failure.issue.displayText))]
            default:
                applyAnthropicTransient(failure.issue)
            }
        case .failure(let issue as RedactedIssue):
            applyAnthropicTransient(issue)
        case .failure:
            applyAnthropicTransient(.anthropicNetworkUnavailable)
        }
    }

    private func applyCodexFailure(_ issue: RedactedIssue) {
        session = staleOrUnavailable(session, issue: issue)
        weekly = staleOrUnavailable(weekly, issue: issue)
    }

    private func applyAnthropicTransient(_ issue: RedactedIssue) {
        let failureTime = now()
        let stale = anthropicReadings.compactMap { prior -> UsageReading? in
            guard let observation = prior.state.observation,
                  observation.resetAt.map({ $0 > failureTime }) ?? true else { return nil }
            var reading = prior
            reading.state = .stale(observation, issue)
            return reading
        }
        anthropicReadings = stale.isEmpty
            ? [Self.anthropicStatus(.unavailable(issue))]
            : stale
    }

    private func staleOrUnavailable(_ previous: ReadingState, issue: RedactedIssue) -> ReadingState {
        if let exactPriorObservation = previous.observation {
            return .stale(exactPriorObservation, issue)
        }
        return .unavailable(issue)
    }

    private static func anthropicStatus(_ state: ReadingState) -> UsageReading {
        UsageReading(
            id: .anthropicStatus,
            provider: .anthropic,
            title: "Claude subscription quota",
            scopeDescription: "Consumer · local Claude Code · undocumented provider-owned OAuth usage interface",
            state: state
        )
    }
}

private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}

struct SurfaceReading: Equatable {
    let key: ReadingKey
    let state: String
    let observationID: String?
    let observedAt: Date?
}

enum UsagePresentation {
    @MainActor
    static func snapshot(from store: UsageStore) -> [SurfaceReading] {
        store.readings.map {
            SurfaceReading(
                key: $0.id,
                state: $0.state.statusName,
                observationID: $0.state.observation?.id,
                observedAt: $0.state.observation?.observedAt
            )
        }
    }
}

enum ReadingFixtures {
    static let observation: UsageObservation = {
        UsageObservation(
            scope: ObservationScope(
                provider: .openAI,
                accountReference: StableIdentifier.opaqueAccountReference(from: "fixture-account"),
                productSurface: .consumer,
                resource: "codex-session",
                unit: .percent,
                intervalSeconds: 18_000,
                provenance: "fixture:usedPercent"
            ),
            kind: .rateLimit,
            used: 82,
            remaining: 18,
            limit: 100,
            resetAt: Date(timeIntervalSince1970: 1_800_018_000),
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            confidence: .derived
        )
    }()

    static let current = ReadingState.current(observation)
    static let stale = ReadingState.stale(observation, .protocolEOF)
    static let unavailable = ReadingState.unavailable(.executableMissing)
    static let authRequired = ReadingState.authRequired(.anthropicAuthRequired)
    static let unsupported = ReadingState.unsupported("No official interface")
    static let unknown = ReadingState.unknown("Supported field not present")
}
