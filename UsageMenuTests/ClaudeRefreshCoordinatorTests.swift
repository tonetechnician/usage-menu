import Foundation
import XCTest
@testable import UsageMenu

final class ClaudeRefreshCoordinatorTests: XCTestCase {
    func testRefreshesOnceThenRetriesQuotaOnce() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let url = try credentialFile(expiredAt: now.addingTimeInterval(-1), refreshExpiresAt: now.addingTimeInterval(3600))
        let refresher = FakeRefresher(result: .success(refresh(now: now)))
        let coordinator = ClaudeRefreshCoordinator(store: ClaudeCredentialFileStore(url: url), refresher: refresher, now: { now })
        var quotaCalls = 0
        let result: String = try await coordinator.fetchQuota {
            quotaCalls += 1
            if quotaCalls == 1 { throw AnthropicSourceFailure(.anthropicAuthRequired) }
            return "quota"
        }
        XCTAssertEqual(result, "quota")
        XCTAssertEqual(quotaCalls, 2)
        XCTAssertEqual(refresher.calls, 1)
    }

    func testTerminalAndMalformedRefreshBecomeAuthRequiredWithoutQuotaRetry() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for failure in [ClaudeRefreshFailure.terminal, .malformed] {
            let url = try credentialFile(expiredAt: now.addingTimeInterval(-1), refreshExpiresAt: now.addingTimeInterval(3600))
            let coordinator = ClaudeRefreshCoordinator(store: ClaudeCredentialFileStore(url: url), refresher: FakeRefresher(result: .failure(failure)), now: { now })
            var quotaCalls = 0
            do {
                let _: String = try await coordinator.fetchQuota { quotaCalls += 1; throw AnthropicSourceFailure(.anthropicAuthRequired) }
                XCTFail("expected auth-required")
            } catch let issue as AnthropicSourceFailure {
                XCTAssertEqual(issue.issue, .anthropicAuthRequired)
            }
            XCTAssertEqual(quotaCalls, 1)
        }
    }

    private var directories: [URL] = []
    override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func credentialFile(expiredAt: Date, refreshExpiresAt: Date) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let root: [String: Any] = ["claudeAiOauth": ["accessToken": "access-canary", "refreshToken": "refresh-canary", "expiresAt": Int64(expiredAt.timeIntervalSince1970 * 1000), "refreshTokenExpiresAt": Int64(refreshExpiresAt.timeIntervalSince1970 * 1000), "scopes": ["user:inference"], "subscriptionType": "fixture", "rateLimitTier": "fixture"]]
        let url = directory.appendingPathComponent(".credentials.json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }
    private func refresh(now: Date) -> ClaudeOAuthRefresh { ClaudeOAuthRefresh(accessToken: "new-access-canary", refreshToken: "new-refresh-canary", expiresAt: now.addingTimeInterval(3600), refreshTokenExpiresAt: now.addingTimeInterval(7200), scopes: ["user:inference"], subscriptionType: "fixture", rateLimitTier: "fixture") }
}

private final class FakeRefresher: ClaudeTokenRefreshing {
    let result: Result<ClaudeOAuthRefresh, Error>
    private(set) var calls = 0
    init(result: Result<ClaudeOAuthRefresh, Error>) { self.result = result }
    func refresh(_ session: ClaudeOAuthSession) async throws -> ClaudeOAuthRefresh { calls += 1; return try result.get() }
}
