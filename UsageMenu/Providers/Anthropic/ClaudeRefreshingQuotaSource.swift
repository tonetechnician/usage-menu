import Foundation

/// Adds the sanctioned silent-refresh/retry boundary around the existing provider-owned quota
/// acquisition. The concrete OAuth adapter owns no persistent secrets beyond the measured file.
final class ClaudeRefreshingQuotaSource: AnthropicUsageSource {
    private let quota: AnthropicUsageSource
    private let coordinator: ClaudeRefreshCoordinator

    init(
        quota: AnthropicUsageSource = AnthropicQuotaSource(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let directory = environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        self.quota = quota
        coordinator = ClaudeRefreshCoordinator(
            store: ClaudeCredentialFileStore(url: directory.appendingPathComponent(".credentials.json")),
            refresher: AnthropicClaudeOAuthRefresher()
        )
    }

    func fetch() async throws -> AnthropicSnapshot { try await coordinator.fetchQuota { try await quota.fetch() } }
    func cancel() { quota.cancel() }
}
