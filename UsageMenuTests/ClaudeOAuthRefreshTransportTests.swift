import Foundation
import XCTest
@testable import UsageMenu

final class ClaudeOAuthRefreshTransportTests: XCTestCase {
    func testParsesRequiredFieldsAndPreservesOptionalPriorRotationState() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let prior = try session(now: now)
        let data = try JSONSerialization.data(withJSONObject: ["access_token": "new-access-canary", "expires_in": 3600])
        let refreshed = try AnthropicClaudeOAuthRefresher.parse(data, prior: prior, now: now)
        XCTAssertEqual(refreshed.refreshToken, prior.refreshToken)
        XCTAssertEqual(refreshed.refreshTokenExpiresAt, prior.refreshTokenExpiresAt)
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(3600))
    }

    func testParsesRotationAndRejectsMalformedResponses() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let prior = try session(now: now)
        let valid = try JSONSerialization.data(withJSONObject: ["access_token": "new-access-canary", "expires_in": 3600, "refresh_token": "new-refresh-canary", "refresh_token_expires_in": 7200])
        let refreshed = try AnthropicClaudeOAuthRefresher.parse(valid, prior: prior, now: now)
        XCTAssertEqual(refreshed.refreshToken, "new-refresh-canary")
        XCTAssertEqual(refreshed.refreshTokenExpiresAt, now.addingTimeInterval(7200))
        for object in [[String: Any](), ["access_token": "x"], ["access_token": "x", "expires_in": 0], ["access_token": "x", "expires_in": 1, "refresh_token_expires_in": 0]] {
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try AnthropicClaudeOAuthRefresher.parse(data, prior: prior, now: now)) { XCTAssertEqual($0 as? ClaudeRefreshFailure, .malformed) }
        }
    }

    func testProductionEndpointIsExactHTTPSProviderOwnedTokenRoute() {
        XCTAssertEqual(AnthropicClaudeOAuthRefresher.productionOrigin.scheme, "https")
        XCTAssertEqual(AnthropicClaudeOAuthRefresher.productionOrigin.host, "api.anthropic.com")
        XCTAssertEqual(AnthropicClaudeOAuthRefresher.tokenPath, "/v1/oauth/token")
    }

    private func session(now: Date) throws -> ClaudeOAuthSession {
        try XCTUnwrap(ClaudeOAuthSession(root: ["claudeAiOauth": ["accessToken": "access-canary", "refreshToken": "refresh-canary", "expiresAt": Int64(now.timeIntervalSince1970 * 1000), "refreshTokenExpiresAt": Int64(now.addingTimeInterval(86400).timeIntervalSince1970 * 1000), "scopes": ["user:inference"], "subscriptionType": "fixture", "rateLimitTier": "fixture"]]))
    }
}
