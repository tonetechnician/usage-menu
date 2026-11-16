import Foundation
import Security

protocol ClaudeCredentialProviding: AnyObject {
    func readCredential() throws -> ClaudeCredential
}

struct ClaudeCredential {
    fileprivate let accessToken: String

    init(accessToken: String) {
        self.accessToken = accessToken
    }
}

protocol ClaudeKeychainReading: AnyObject {
    func read(service: String, account: String) throws -> Data?
}

final class SystemClaudeKeychainReader: ClaudeKeychainReading {
    func read(service: String, account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw RedactedIssue.anthropicKeychainDenied
        }
        return data
    }
}

final class LocalClaudeCredentialProvider: ClaudeCredentialProviding {
    static let keychainService = "Claude Code-credentials"
    static let fallbackKeychainAccount = "claude-code-user"

    private let environment: [String: String]
    private let homeDirectory: URL
    private let keychain: ClaudeKeychainReading
    private let operatingSystemUsername: () -> String
    private let maximumCredentialBytes: Int
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychain: ClaudeKeychainReading = SystemClaudeKeychainReader(),
        operatingSystemUsername: @escaping () -> String = { NSUserName() },
        maximumCredentialBytes: Int = 64 * 1024,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.keychain = keychain
        self.operatingSystemUsername = operatingSystemUsername
        self.maximumCredentialBytes = maximumCredentialBytes
        self.fileManager = fileManager
    }

    var credentialFileURL: URL {
        let directory: URL
        if let configured = environment["CLAUDE_CONFIG_DIR"] {
            directory = URL(fileURLWithPath: configured.precomposedStringWithCanonicalMapping, isDirectory: true)
        } else {
            directory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        return directory.appendingPathComponent(".credentials.json", isDirectory: false)
    }

    var keychainAccount: String {
        if let environmentUser = environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentUser.isEmpty {
            return isSafeAccount(environmentUser) ? environmentUser : Self.fallbackKeychainAccount
        }
        let systemUser = operatingSystemUsername().trimmingCharacters(in: .whitespacesAndNewlines)
        if isSafeAccount(systemUser) { return systemUser }
        return Self.fallbackKeychainAccount
    }

    /// Claude Code's own read order: the Keychain item, and the file only when no item exists.
    /// A denied Keychain read is reported, never masked by a file that Claude Code would not use.
    func readCredential() throws -> ClaudeCredential {
        let keychainData: Data?
        do {
            keychainData = try keychain.read(service: Self.keychainService, account: keychainAccount)
        } catch {
            throw RedactedIssue.anthropicKeychainDenied
        }
        if let data = keychainData {
            guard data.count > 0, data.count <= maximumCredentialBytes else {
                throw RedactedIssue.anthropicCredentialsInvalid
            }
            return try Self.decodeCredential(data)
        }

        let fileURL = credentialFileURL
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw RedactedIssue.anthropicCredentialsMissing
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue > 0, size.intValue <= maximumCredentialBytes else {
                throw RedactedIssue.anthropicCredentialsInvalid
            }
            let data = try Data(contentsOf: fileURL, options: [])
            guard data.count <= maximumCredentialBytes else {
                throw RedactedIssue.anthropicCredentialsInvalid
            }
            return try Self.decodeCredential(data)
        } catch let issue as RedactedIssue {
            throw issue
        } catch {
            throw RedactedIssue.anthropicCredentialsInvalid
        }
    }

    private static func decodeCredential(_ data: Data) throws -> ClaudeCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RedactedIssue.anthropicCredentialsInvalid
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        let token = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw RedactedIssue.anthropicCredentialsInvalid
        }
        if credentialExpiry(in: oauth).map({ $0 <= Date() }) == true {
            throw RedactedIssue.anthropicCredentialsExpired
        }
        return ClaudeCredential(accessToken: token)
    }

    /// Claude Code owns renewal. We only classify an expiry already recorded by that provider;
    /// this app never refreshes, persists, or copies the credential.
    private static func credentialExpiry(in oauth: [String: Any]) -> Date? {
        let raw = oauth["expiresAt"] ?? oauth["expires_at"] ?? oauth["expires_at_ms"]
        guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private func isSafeAccount(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }
}

struct AnthropicNetworkResponse {
    let statusCode: Int
    let retryAfter: String?
    let body: Data
}

protocol AnthropicNetworkClient: AnyObject {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AnthropicNetworkResponse
    func cancel()
}

final class AnthropicURLSessionClient: AnthropicNetworkClient {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AnthropicNetworkResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RedactedIssue.anthropicNetworkUnavailable
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 16 * 1024))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw RedactedIssue.anthropicResponseOversized
            }
            data.append(byte)
        }
        return AnthropicNetworkResponse(
            statusCode: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            body: data
        )
    }

    func cancel() {
        session.invalidateAndCancel()
    }
}

struct AnthropicSourceFailure: Error, Equatable {
    let issue: RedactedIssue
    let retryAfter: Date?

    init(_ issue: RedactedIssue, retryAfter: Date? = nil) {
        self.issue = issue
        self.retryAfter = retryAfter
    }
}

protocol AnthropicUsageSource: CancellableUsageSource {
    func fetch() async throws -> AnthropicSnapshot
}

final class AnthropicQuotaSource: AnthropicUsageSource {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.202"

    private let credentials: ClaudeCredentialProviding
    private let network: AnthropicNetworkClient
    private let maximumResponseBytes: Int
    private let now: () -> Date

    init(
        credentials: ClaudeCredentialProviding = LocalClaudeCredentialProvider(),
        network: AnthropicNetworkClient = AnthropicURLSessionClient(),
        maximumResponseBytes: Int = 256 * 1024,
        now: @escaping () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.network = network
        self.maximumResponseBytes = maximumResponseBytes
        self.now = now
    }

    func fetch() async throws -> AnthropicSnapshot {
        let credential: ClaudeCredential
        do {
            credential = try credentials.readCredential()
        } catch let issue as RedactedIssue {
            throw AnthropicSourceFailure(issue)
        } catch {
            throw AnthropicSourceFailure(.anthropicCredentialsInvalid)
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: AnthropicNetworkResponse
        do {
            response = try await network.send(request, maximumResponseBytes: maximumResponseBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch let issue as RedactedIssue {
            throw AnthropicSourceFailure(issue)
        } catch let error as URLError where error.code == .timedOut {
            throw AnthropicSourceFailure(.anthropicTimeout)
        } catch {
            throw AnthropicSourceFailure(.anthropicNetworkUnavailable)
        }

        switch response.statusCode {
        case 200..<300:
            do {
                return try AnthropicQuotaMapper.map(data: response.body, observedAt: now())
            } catch {
                throw AnthropicSourceFailure(.anthropicUnknownResponse)
            }
        case 401, 403:
            throw AnthropicSourceFailure(.anthropicAuthRequired)
        case 429:
            throw AnthropicSourceFailure(
                .anthropicRateLimited,
                retryAfter: Self.parseRetryAfter(response.retryAfter, now: now())
            )
        case 500..<600:
            throw AnthropicSourceFailure(.anthropicServerUnavailable)
        default:
            throw AnthropicSourceFailure(.anthropicNetworkUnavailable)
        }
    }

    func cancel() {
        network.cancel()
    }

    private static func parseRetryAfter(_ value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

enum AnthropicQuotaMapper {
    private static let accountReference = "local_claude_code"
    private static let sourceDescription = "Consumer · local Claude Code · undocumented provider-owned OAuth usage interface"

    static func map(data: Data, observedAt: Date) throws -> AnthropicSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RedactedIssue.anthropicUnknownResponse
        }

        var readings: [AnthropicQuotaReading]
        if let limits = root["limits"] as? [Any], !limits.isEmpty {
            readings = limits.enumerated().compactMap { mapLimit($0.element, index: $0.offset, observedAt: observedAt) }
        } else {
            readings = [
                mapLegacyWindow(root["five_hour"], providerID: "five_hour", title: "Claude session", interval: 18_000, observedAt: observedAt),
                mapLegacyWindow(root["seven_day"], providerID: "seven_day", title: "Claude weekly", interval: 604_800, observedAt: observedAt),
                mapLegacyWindow(root["seven_day_opus"], providerID: "seven_day_opus", title: "Claude Opus weekly", interval: 604_800, observedAt: observedAt)
            ].compactMap { $0 }
        }
        if let extra = mapExtraUsage(root["extra_usage"], observedAt: observedAt) {
            readings.append(extra)
        }

        var seen = Set<ReadingKey>()
        readings = readings.filter { seen.insert($0.key).inserted }
        guard !readings.isEmpty else { throw RedactedIssue.anthropicUnknownResponse }
        return AnthropicSnapshot(readings: readings)
    }

    private static func mapLegacyWindow(
        _ raw: Any?,
        providerID: String,
        title: String,
        interval: Int,
        observedAt: Date
    ) -> AnthropicQuotaReading? {
        guard let object = raw as? [String: Any],
              let used = validPercent(object["utilization"]) else { return nil }
        return percentReading(
            providerID: providerID,
            title: title,
            resource: "claude-\(providerID.replacingOccurrences(of: "_", with: "-"))",
            interval: interval,
            provenance: "api/oauth/usage:\(providerID).utilization",
            used: used,
            resetAt: parseDate(object["resets_at"] ?? object["reset_at"]),
            observedAt: observedAt,
            scopeDescription: sourceDescription
        )
    }

    private static func mapLimit(_ raw: Any, index: Int, observedAt: Date) -> AnthropicQuotaReading? {
        guard let object = raw as? [String: Any], let used = validPercent(object["percent"]) else { return nil }
        let reset = parseDate(object["resets_at"])
        let group = nonemptyString(object["group"])
        let kind = nonemptyString(object["kind"])
        let scope = object["scope"] as? [String: Any]
        let model = scope?["model"] as? [String: Any]
        if let modelName = nonemptyString(model?["display_name"]) {
            let modelID = nonemptyString(model?["id"]) ?? slug(modelName)
            return percentReading(
                providerID: "model-\(modelID)",
                title: "Claude \(modelName) weekly",
                resource: "claude-model-\(modelID)",
                interval: 604_800,
                provenance: "api/oauth/usage:limits[].scope.model+percent",
                used: used,
                resetAt: reset,
                observedAt: observedAt,
                scopeDescription: sourceDescription + " · model-scoped weekly window"
            )
        }
        if group == "session" {
            return percentReading(
                providerID: "five_hour", title: "Claude session", resource: "claude-five-hour",
                interval: 18_000, provenance: "api/oauth/usage:limits[].group=session+percent",
                used: used, resetAt: reset, observedAt: observedAt, scopeDescription: sourceDescription
            )
        }
        if group == "weekly" {
            return percentReading(
                providerID: "seven_day", title: "Claude weekly", resource: "claude-seven-day",
                interval: 604_800, provenance: "api/oauth/usage:limits[].group=weekly+percent",
                used: used, resetAt: reset, observedAt: observedAt, scopeDescription: sourceDescription
            )
        }

        let providerID = slug(kind ?? group ?? "limit-\(index)")
        return percentReading(
            providerID: "limit-\(providerID)",
            title: "Claude \((kind ?? group ?? "provider-defined").replacingOccurrences(of: "_", with: " ")) limit",
            resource: "claude-provider-limit-\(providerID)",
            interval: nil,
            provenance: "api/oauth/usage:limits[].kind+percent",
            used: used,
            resetAt: reset,
            observedAt: observedAt,
            scopeDescription: sourceDescription + " · provider-defined window semantics unknown"
        )
    }

    private static func mapExtraUsage(_ raw: Any?, observedAt: Date) -> AnthropicQuotaReading? {
        guard let object = raw as? [String: Any], object["is_enabled"] as? Bool == true else { return nil }
        let decimalPlaces = (object["decimal_places"] as? NSNumber)?.intValue ?? 2
        guard (0...6).contains(decimalPlaces) else { return nil }
        let divisor = pow(10.0, Double(decimalPlaces))
        let used = validNonnegative(object["used_credits"]).map { $0 / divisor }
        let limit = validNonnegative(object["monthly_limit"]).map { $0 / divisor }
        let utilization = validPercent(object["utilization"])
        guard used != nil || limit != nil || utilization != nil else { return nil }
        let remaining: Double?
        if let used, let limit, used <= limit { remaining = limit - used } else if let utilization { remaining = 100 - utilization } else { remaining = nil }
        let usesCurrency = used != nil || limit != nil
        let scope = ObservationScope(
            provider: .anthropic,
            accountReference: accountReference,
            productSurface: .consumer,
            resource: usesCurrency ? "claude-extra-usage-usd" : "claude-extra-usage-percent",
            unit: usesCurrency ? .currency : .percent,
            intervalSeconds: nil,
            provenance: usesCurrency
                ? "api/oauth/usage:extra_usage.used_credits+monthly_limit"
                : "api/oauth/usage:extra_usage.utilization"
        )
        let observation = UsageObservation(
            scope: scope,
            kind: .cost,
            used: usesCurrency ? used : utilization,
            remaining: remaining,
            limit: usesCurrency ? limit : 100,
            resetAt: parseDate(object["resets_at"] ?? object["reset_at"]),
            observedAt: observedAt,
            confidence: remaining == nil ? .authoritative : .derived
        )
        return AnthropicQuotaReading(
            key: .anthropic("extra-usage"),
            title: "Claude extra usage",
            scopeDescription: sourceDescription + (usesCurrency ? " · separate USD cost allowance" : " · separate extra-usage utilization"),
            observation: observation
        )
    }

    private static func percentReading(
        providerID: String,
        title: String,
        resource: String,
        interval: Int?,
        provenance: String,
        used: Double,
        resetAt: Date?,
        observedAt: Date,
        scopeDescription: String
    ) -> AnthropicQuotaReading {
        let scope = ObservationScope(
            provider: .anthropic,
            accountReference: accountReference,
            productSurface: .consumer,
            resource: resource,
            unit: .percent,
            intervalSeconds: interval,
            provenance: provenance
        )
        let observation = UsageObservation(
            scope: scope,
            kind: .quota,
            used: used,
            remaining: 100 - used,
            limit: 100,
            resetAt: resetAt,
            observedAt: observedAt,
            confidence: .derived
        )
        return AnthropicQuotaReading(
            key: .anthropic(providerID),
            title: title,
            scopeDescription: scopeDescription,
            observation: observation
        )
    }

    static func validatedPercent(_ value: Double) -> Double? {
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func validPercent(_ raw: Any?) -> Double? {
        guard let value = (raw as? NSNumber)?.doubleValue else { return nil }
        return validatedPercent(value)
    }

    private static func validNonnegative(_ raw: Any?) -> Double? {
        guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func nonemptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let pieces = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return pieces.joined(separator: "-")
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = nonemptyString(raw) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: value)
    }
}

final class FixtureAnthropicSource: AnthropicUsageSource {
    func fetch() async throws -> AnthropicSnapshot {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "five_hour": ["utilization": 13, "resets_at": "2027-01-15T13:00:00Z"],
            "seven_day": ["utilization": 47, "resets_at": "2027-01-20T08:00:00Z"]
        ])
        return try AnthropicQuotaMapper.map(data: data, observedAt: observedAt)
    }

    func cancel() {}
}
