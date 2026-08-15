import Foundation
import XCTest
@testable import UsageMenu

final class ClaudeRefreshFoundationTests: XCTestCase {
    func testMeasuredCamelCaseMillisecondsDriveRefreshDecision() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let session = try makeSession(expiresAt: now.addingTimeInterval(-1), refreshExpiresAt: now.addingTimeInterval(4 * 24 * 60 * 60))
        XCTAssertEqual(session.refreshDecision(now: now), .refresh)
        XCTAssertEqual(try makeSession(expiresAt: now.addingTimeInterval(120), refreshExpiresAt: now.addingTimeInterval(1_000)).refreshDecision(now: now), .current)
        XCTAssertEqual(try makeSession(expiresAt: now.addingTimeInterval(-1), refreshExpiresAt: now.addingTimeInterval(-1)).refreshDecision(now: now), .authRequired)
    }

    func testRejectsSecondsAndIncompleteMeasuredShape() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var root = root(expiresAt: now, refreshExpiresAt: now.addingTimeInterval(60))
        var oauth = root["claudeAiOauth"] as! [String: Any]
        oauth["expiresAt"] = 2_000_000_000
        root["claudeAiOauth"] = oauth
        XCTAssertNil(ClaudeOAuthSession(root: root))
        oauth.removeValue(forKey: "refreshTokenExpiresAt")
        root["claudeAiOauth"] = oauth
        XCTAssertNil(ClaudeOAuthSession(root: root))
    }

    func testAtomicReplacePreservesUnrelatedRootAndOAuthFields() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(".credentials.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var original = root(expiresAt: now.addingTimeInterval(-1), refreshExpiresAt: now.addingTimeInterval(3600))
        original["unrelatedRoot"] = ["keep": "canary"]
        var oauth = original["claudeAiOauth"] as! [String: Any]
        oauth["unrelatedOAuth"] = "keep"
        original["claudeAiOauth"] = oauth
        let initial = try JSONSerialization.data(withJSONObject: original)
        try initial.write(to: url)

        let result = try ClaudeCredentialFileStore(url: url).replace(expectedData: initial, with: refresh(now: now))
        XCTAssertEqual(result, .saved)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual((stored["unrelatedRoot"] as? [String: String])?["keep"], "canary")
        XCTAssertEqual(((stored["claudeAiOauth"] as? [String: Any])?["unrelatedOAuth"] as? String), "keep")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(try XCTUnwrap(permissions).intValue & 0o777, 0o600)
    }

    func testCASAdoptsSiblingWithoutOverwriting() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(".credentials.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let initial = try JSONSerialization.data(withJSONObject: root(expiresAt: now, refreshExpiresAt: now.addingTimeInterval(3600)))
        try initial.write(to: url)
        let sibling = try JSONSerialization.data(withJSONObject: root(expiresAt: now.addingTimeInterval(500), refreshExpiresAt: now.addingTimeInterval(3600)))
        try sibling.write(to: url)
        XCTAssertEqual(try ClaudeCredentialFileStore(url: url).replace(expectedData: initial, with: refresh(now: now)), .adoptedSibling)
        XCTAssertEqual(try Data(contentsOf: url), sibling)
    }

    private var directories: [URL] = []
    override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); directories.append(url); return url }
    private func makeSession(expiresAt: Date, refreshExpiresAt: Date) throws -> ClaudeOAuthSession { try XCTUnwrap(ClaudeOAuthSession(root: root(expiresAt: expiresAt, refreshExpiresAt: refreshExpiresAt))) }
    private func root(expiresAt: Date, refreshExpiresAt: Date) -> [String: Any] { ["claudeAiOauth": ["accessToken": "access-canary", "refreshToken": "refresh-canary", "expiresAt": Int64(expiresAt.timeIntervalSince1970 * 1000), "refreshTokenExpiresAt": Int64(refreshExpiresAt.timeIntervalSince1970 * 1000), "scopes": ["user:inference"], "subscriptionType": "fixture", "rateLimitTier": "fixture"]] }
    private func refresh(now: Date) -> ClaudeOAuthRefresh { ClaudeOAuthRefresh(accessToken: "rotated-access-canary", refreshToken: "rotated-refresh-canary", expiresAt: now.addingTimeInterval(3600), refreshTokenExpiresAt: now.addingTimeInterval(7200), scopes: ["user:inference"], subscriptionType: "fixture", rateLimitTier: "fixture") }
}
