import Foundation

/// Coordinates an already-established provider refresh protocol with quota acquisition. This
/// type intentionally has no endpoint or request construction; that adapter is pending sanction.
final class ClaudeRefreshCoordinator {
    private let store: ClaudeCredentialFileStore
    private let refresher: ClaudeTokenRefreshing
    private let flight = ClaudeRefreshSingleFlight()
    private let now: () -> Date

    init(
        store: ClaudeCredentialFileStore,
        refresher: ClaudeTokenRefreshing,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.refresher = refresher
        self.now = now
    }

    /// Executes quota acquisition once, performs at most one silent refresh on an authentication
    /// failure, then retries quota acquisition exactly once after a persisted successful refresh.
    func fetchQuota<T>(_ fetch: () async throws -> T) async throws -> T {
        do { return try await fetch() }
        catch let failure as AnthropicSourceFailure where failure.issue == .anthropicAuthRequired {
            try await refreshIfEligible()
            return try await fetch()
        }
    }

    private func refreshIfEligible() async throws {
        let current = try store.read()
        switch current.session.refreshDecision(now: now()) {
        case .current:
            throw AnthropicSourceFailure(.anthropicAuthRequired)
        case .authRequired:
            throw AnthropicSourceFailure(.anthropicAuthRequired)
        case .refresh:
            do {
                let refresh = try await flight.run { [refresher] in
                    try await refresher.refresh(current.session)
                }
                switch try store.replace(expectedData: current.data, with: refresh) {
                case .saved, .adoptedSibling: return
                }
            } catch let failure as ClaudeRefreshFailure where failure == .terminal || failure == .malformed {
                throw AnthropicSourceFailure(.anthropicAuthRequired)
            } catch let failure as RedactedIssue {
                throw AnthropicSourceFailure(failure)
            } catch {
                throw AnthropicSourceFailure(.anthropicAuthRequired)
            }
        }
    }
}
