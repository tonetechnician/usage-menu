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
        // An expired measured file shape is rejected by LocalClaudeCredentialProvider before the
        // quota request. Refresh it here rather than waiting for a 401 that cannot occur.
        if let current = try? store.read(), current.session.refreshDecision(now: now()) == .refresh {
            try await refreshIfEligible(forceAfterProviderAuthFailure: false)
            return try await fetch()
        }
        do { return try await fetch() }
        catch let failure as AnthropicSourceFailure where failure.issue == .anthropicAuthRequired || failure.issue == .anthropicCredentialsExpired {
            try await refreshIfEligible(forceAfterProviderAuthFailure: true)
            return try await fetch()
        }
    }

    private func refreshIfEligible(forceAfterProviderAuthFailure: Bool) async throws {
        do {
            try await store.withRefreshLock { [store, refresher, now] in
                let current = try store.read()
                switch current.session.refreshDecision(now: now()) {
                case .authRequired:
                    throw AnthropicSourceFailure(.anthropicAuthRequired)
                case .current where !forceAfterProviderAuthFailure:
                    // A sibling rotated while this process waited for the provider lock.
                    return
                case .current, .refresh:
                    let refresh = try await self.flight.run { try await refresher.refresh(current.session) }
                    _ = try store.replace(expectedData: current.data, with: refresh)
                }
            }
        } catch let failure as AnthropicSourceFailure { throw failure }
        catch {
            // Transport, malformed response, lock/file/write failures never leak details or
            // leave an ambiguous session state: provider-owned login is the recovery path.
            throw AnthropicSourceFailure(.anthropicAuthRequired)
        }
    }
}
