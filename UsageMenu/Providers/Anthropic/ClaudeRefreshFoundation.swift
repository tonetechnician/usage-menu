import Foundation
import Darwin

/// Provider transport is deliberately absent until the provider-owned observation establishes it.
/// Implementations receive secret material only in request memory.
protocol ClaudeTokenRefreshing: AnyObject {
    func refresh(_ session: ClaudeOAuthSession) async throws -> ClaudeOAuthRefresh
}

protocol ClaudeOAuthSessionProviding: AnyObject {
    func readOAuthSession() throws -> ClaudeOAuthSession
}

struct ClaudeOAuthSession {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let refreshTokenExpiresAt: Date
    let scopes: [String]
    let subscriptionType: String
    let rateLimitTier: String

    init?(root: [String: Any]) {
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty,
              let expiresAt = Self.millisecondDate(oauth["expiresAt"]),
              let refreshTokenExpiresAt = Self.millisecondDate(oauth["refreshTokenExpiresAt"]),
              let scopes = oauth["scopes"] as? [String],
              let subscriptionType = oauth["subscriptionType"] as? String,
              let rateLimitTier = oauth["rateLimitTier"] as? String else { return nil }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    private static func millisecondDate(_ raw: Any?) -> Date? {
        guard let number = raw as? NSNumber,
              number.doubleValue.isFinite,
              number.doubleValue > 10_000_000_000,
              floor(number.doubleValue) == number.doubleValue else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1_000)
    }

    enum RefreshDecision: Equatable {
        case current
        case refresh
        case authRequired
    }

    func refreshDecision(now: Date, skew: TimeInterval = 60) -> RefreshDecision {
        guard refreshTokenExpiresAt > now else { return .authRequired }
        return expiresAt <= now.addingTimeInterval(skew) ? .refresh : .current
    }
}

/// Wire-neutral normalized result. A future provider protocol adapter must validate its raw
/// response before constructing this value.
struct ClaudeOAuthRefresh {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let refreshTokenExpiresAt: Date
    let scopes: [String]
    let subscriptionType: String
    let rateLimitTier: String
}

enum ClaudeRefreshFailure: Error, Equatable {
    case terminal
    case malformed
    case unavailable
}

/// Serializes refresh attempts in-process. File storage additionally performs a CAS so a
/// different Claude Code process wins rather than being overwritten.
actor ClaudeRefreshSingleFlight {
    private var operation: Task<ClaudeOAuthRefresh, Error>?

    func run(_ work: @escaping @Sendable () async throws -> ClaudeOAuthRefresh) async throws -> ClaudeOAuthRefresh {
        if let operation { return try await operation.value }
        let task = Task { try await work() }
        operation = task
        defer { operation = nil }
        return try await task.value
    }
}

/// File-only persistence for the measured active Claude Code store. It never reads or writes
/// Keychain and has no network behavior.
final class ClaudeCredentialFileStore {
    enum WriteResult: Equatable { case saved, adoptedSibling }

    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func read() throws -> (data: Data, root: [String: Any], session: ClaudeOAuthSession) {
        let data = try Data(contentsOf: url, options: [])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = ClaudeOAuthSession(root: root) else { throw RedactedIssue.anthropicCredentialsInvalid }
        return (data, root, session)
    }

    func withRefreshLock<T>(timeout: TimeInterval = 5, operation: () async throws -> T) async throws -> T {
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".oauth_refresh.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ClaudeRefreshFailure.unavailable }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw ClaudeRefreshFailure.unavailable }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await operation()
    }

    func replace(expectedData: Data, with refresh: ClaudeOAuthRefresh) throws -> WriteResult {
        let current = try read()
        guard current.data == expectedData else { return .adoptedSibling }
        var root = current.root
        guard var oauth = root["claudeAiOauth"] as? [String: Any] else { throw RedactedIssue.anthropicCredentialsInvalid }
        oauth["accessToken"] = refresh.accessToken
        oauth["refreshToken"] = refresh.refreshToken
        oauth["expiresAt"] = Int64(refresh.expiresAt.timeIntervalSince1970 * 1_000)
        oauth["refreshTokenExpiresAt"] = Int64(refresh.refreshTokenExpiresAt.timeIntervalSince1970 * 1_000)
        oauth["scopes"] = refresh.scopes
        oauth["subscriptionType"] = refresh.subscriptionType
        oauth["rateLimitTier"] = refresh.rateLimitTier
        root["claudeAiOauth"] = oauth
        let replacement = try JSONSerialization.data(withJSONObject: root, options: [])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".credentials.\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try replacement.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let latest = try Data(contentsOf: url, options: [])
        guard latest == expectedData else { return .adoptedSibling }
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return .saved
    }
}
