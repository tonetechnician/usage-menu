import Foundation

/// RFC 6749 refresh adapter for the production Anthropic origin embedded in Claude Code.
/// The origin is fixed rather than caller-configurable so credentials cannot be sent elsewhere.
final class AnthropicClaudeOAuthRefresher: ClaudeTokenRefreshing {
    static let productionOrigin = URL(string: "https://api.anthropic.com")!
    static let tokenPath = "/v1/oauth/token"
    private let session: URLSession
    private let now: () -> Date

    init(session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 1
            self.session = URLSession(configuration: configuration)
        }
        self.now = now
    }

    func refresh(_ sessionState: ClaudeOAuthSession) async throws -> ClaudeOAuthRefresh {
        guard Self.productionOrigin.scheme == "https", Self.productionOrigin.host == "api.anthropic.com" else {
            throw ClaudeRefreshFailure.unavailable
        }
        var components = URLComponents(url: Self.productionOrigin, resolvingAgainstBaseURL: false)!
        components.path = Self.tokenPath
        guard let url = components.url else { throw ClaudeRefreshFailure.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = Self.form([("grant_type", "refresh_token"), ("refresh_token", sessionState.refreshToken), ("scope", sessionState.scopes.joined(separator: " "))])
        do {
            let (data, response) = try await self.session.data(for: request, delegate: RedirectRefusingDelegate())
            guard let http = response as? HTTPURLResponse,
                  http.url?.scheme == "https", http.url?.host == Self.productionOrigin.host else { throw ClaudeRefreshFailure.unavailable }
            if http.statusCode == 400 || http.statusCode == 401 {
                if Self.errorCode(in: data) == "invalid_grant" { throw ClaudeRefreshFailure.terminal }
                throw ClaudeRefreshFailure.unavailable
            }
            guard (200..<300).contains(http.statusCode) else { throw ClaudeRefreshFailure.unavailable }
            return try Self.parse(data, prior: sessionState, now: now())
        } catch let failure as ClaudeRefreshFailure { throw failure }
        catch { throw ClaudeRefreshFailure.unavailable }
    }

    static func parse(_ data: Data, prior: ClaudeOAuthSession, now: Date) throws -> ClaudeOAuthRefresh {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue,
              expiresIn.isFinite, expiresIn > 0 else { throw ClaudeRefreshFailure.malformed }
        let refreshToken = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? prior.refreshToken
        let refreshExpiry: Date
        if let seconds = (object["refresh_token_expires_in"] as? NSNumber)?.doubleValue {
            guard seconds.isFinite, seconds > 0 else { throw ClaudeRefreshFailure.malformed }
            refreshExpiry = now.addingTimeInterval(seconds)
        } else { refreshExpiry = prior.refreshTokenExpiresAt }
        return ClaudeOAuthRefresh(accessToken: accessToken, refreshToken: refreshToken, expiresAt: now.addingTimeInterval(expiresIn), refreshTokenExpiresAt: refreshExpiry, scopes: prior.scopes, subscriptionType: prior.subscriptionType, rateLimitTier: prior.rateLimitTier)
    }

    private static func form(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = fields.map { field -> String in
            let name = field.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let value = field.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return name + "=" + value
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
    private static func errorCode(in data: Data) -> String? { (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String }
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
