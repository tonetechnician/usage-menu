import Foundation
import Darwin
import XCTest
@testable import UsageMenu

final class ClaudeRefreshCoordinatorTests: XCTestCase {
    func testRefreshesOnceThenRetriesQuotaOnce() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let url = try credentialFile(expiredAt: now.addingTimeInterval(3600), refreshExpiresAt: now.addingTimeInterval(7200))
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

    func testLockContentionAdoptsSiblingCurrentSessionWithoutSecondRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let url = try credentialFile(expiredAt: now.addingTimeInterval(1), refreshExpiresAt: now.addingTimeInterval(7200))
        let lock = open(url.deletingLastPathComponent().appendingPathComponent(".oauth_refresh.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lock, 0)
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        defer { flock(lock, LOCK_UN); close(lock) }
        let refresher = FakeRefresher(result: .success(refresh(now: now)))
        let coordinator = ClaudeRefreshCoordinator(store: ClaudeCredentialFileStore(url: url), refresher: refresher, now: { now })
        let task = Task { try await coordinator.fetchQuota { "quota" } }
        try await Task.sleep(nanoseconds: 200_000_000)
        try JSONSerialization.data(withJSONObject: credentialRoot(expiredAt: now.addingTimeInterval(3600), refreshExpiresAt: now.addingTimeInterval(7200))).write(to: url, options: .atomic)
        flock(lock, LOCK_UN)
        let result = try await task.value
        XCTAssertEqual(result, "quota")
        XCTAssertEqual(refresher.calls, 0)
    }

    func testLockTimeoutMapsToAuthRequiredGuidance() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let url = try credentialFile(expiredAt: now.addingTimeInterval(1), refreshExpiresAt: now.addingTimeInterval(7200))
        let lock = open(url.deletingLastPathComponent().appendingPathComponent(".oauth_refresh.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        defer { flock(lock, LOCK_UN); close(lock) }
        do {
            try await ClaudeCredentialFileStore(url: url).withRefreshLock(timeout: 0.01) { () -> Void in }
            XCTFail("expected lock timeout")
        } catch let failure as ClaudeRefreshFailure { XCTAssertEqual(failure, .unavailable) }
    }

    func testTerminalAndMalformedRefreshBecomeAuthRequiredWithoutQuotaRetry() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for failure in [ClaudeRefreshFailure.terminal, .malformed] {
            let url = try credentialFile(expiredAt: now.addingTimeInterval(3600), refreshExpiresAt: now.addingTimeInterval(7200))
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
        let root = credentialRoot(expiredAt: expiredAt, refreshExpiresAt: refreshExpiresAt)
        let url = directory.appendingPathComponent(".credentials.json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }
    private func credentialRoot(expiredAt: Date, refreshExpiresAt: Date) -> [String: Any] { ["claudeAiOauth": ["accessToken": "access-canary", "refreshToken": "refresh-canary", "expiresAt": Int64(expiredAt.timeIntervalSince1970 * 1000), "refreshTokenExpiresAt": Int64(refreshExpiresAt.timeIntervalSince1970 * 1000), "scopes": ["user:inference"], "subscriptionType": "fixture", "rateLimitTier": "fixture"]] }
    private func refresh(now: Date) -> ClaudeOAuthRefresh { ClaudeOAuthRefresh(accessToken: "new-access-canary", refreshToken: "new-refresh-canary", expiresAt: now.addingTimeInterval(3600), refreshTokenExpiresAt: now.addingTimeInterval(7200), scopes: ["user:inference"], subscriptionType: "fixture", rateLimitTier: "fixture") }
}

private final class FakeRefresher: ClaudeTokenRefreshing {
    let result: Result<ClaudeOAuthRefresh, Error>
    private(set) var calls = 0
    init(result: Result<ClaudeOAuthRefresh, Error>) { self.result = result }
    func refresh(_ session: ClaudeOAuthSession) async throws -> ClaudeOAuthRefresh { calls += 1; return try result.get() }
}
