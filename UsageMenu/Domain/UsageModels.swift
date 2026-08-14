import CryptoKit
import Foundation

enum Provider: String, Codable, CaseIterable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case local = "This Mac"
}

enum ProductSurface: String, Codable {
    case consumer
    case organization
    case workspace
    case project
    case localSystem = "local_system"
}

enum ObservationKind: String, Codable {
    case usage
    case quota
    case rateLimit = "rate_limit"
    case cost
    case creditBalance = "credit_balance"
    case utilization
}

enum ObservationUnit: String, Codable {
    case percent
    case requests
    case tokens
    case currency
    case bytes
}

enum ObservationConfidence: String, Codable {
    case authoritative
    case derived
    case userEntered = "user_entered"
}

struct ObservationScope: Codable, Equatable, Hashable {
    let provider: Provider
    let accountReference: String
    let productSurface: ProductSurface
    let resource: String
    let unit: ObservationUnit
    let intervalSeconds: Int?
    let provenance: String

    var canonicalIdentity: String {
        [provider.rawValue, accountReference, productSurface.rawValue, resource,
         unit.rawValue, intervalSeconds.map(String.init) ?? "none", provenance]
            .joined(separator: "|")
    }

    func canDerive(with other: ObservationScope) -> Bool {
        self == other
    }
}

struct UsageObservation: Identifiable, Codable, Equatable {
    let id: String
    let scope: ObservationScope
    let kind: ObservationKind
    let used: Double?
    let remaining: Double?
    let limit: Double?
    let windowStartedAt: Date?
    let resetAt: Date?
    let observedAt: Date
    let sourceGeneratedAt: Date?
    let confidence: ObservationConfidence

    init(
        scope: ObservationScope,
        kind: ObservationKind,
        used: Double? = nil,
        remaining: Double? = nil,
        limit: Double? = nil,
        windowStartedAt: Date? = nil,
        resetAt: Date? = nil,
        observedAt: Date,
        sourceGeneratedAt: Date? = nil,
        confidence: ObservationConfidence
    ) {
        self.scope = scope
        self.kind = kind
        self.used = used
        self.remaining = remaining
        self.limit = limit
        self.windowStartedAt = windowStartedAt
        self.resetAt = resetAt
        self.observedAt = observedAt
        self.sourceGeneratedAt = sourceGeneratedAt
        self.confidence = confidence
        self.id = StableIdentifier.make(from: scope.canonicalIdentity + "|" + kind.rawValue)
    }
}

enum RedactedIssue: String, Error, Codable, Equatable, CaseIterable {
    case notRefreshed = "not_refreshed"
    case executableMissing = "executable_missing"
    case executableNotFound = "executable_not_found"
    case processLaunchFailed = "process_launch_failed"
    case processExited = "process_exited"
    case protocolMalformed = "protocol_malformed"
    case protocolOversized = "protocol_oversized"
    case protocolEOF = "protocol_eof"
    case protocolTimeout = "protocol_timeout"
    case protocolRejected = "protocol_rejected"
    case signedOut = "signed_out"
    case missingSupportedField = "missing_supported_field"
    case anthropicCredentialsMissing = "anthropic_credentials_missing"
    case anthropicCredentialsInvalid = "anthropic_credentials_invalid"
    case anthropicCredentialsExpired = "anthropic_credentials_expired"
    case anthropicKeychainDenied = "anthropic_keychain_denied"
    case anthropicAuthRequired = "anthropic_auth_required"
    case anthropicRateLimited = "anthropic_rate_limited"
    case anthropicTimeout = "anthropic_timeout"
    case anthropicNetworkUnavailable = "anthropic_network_unavailable"
    case anthropicServerUnavailable = "anthropic_server_unavailable"
    case anthropicResponseOversized = "anthropic_response_oversized"
    case anthropicUnknownResponse = "anthropic_unknown_response"
    case refreshInProgress = "refresh_in_progress"
    case cancelled

    var displayText: String {
        switch self {
        case .notRefreshed: return "Not refreshed"
        case .executableMissing: return "Configured Codex executable not found"
        case .executableNotFound: return "Codex not found on this Mac"
        case .processLaunchFailed: return "Codex could not start"
        case .processExited: return "Codex app-server exited"
        case .protocolMalformed: return "Codex returned an invalid message"
        case .protocolOversized: return "Codex returned an oversized message"
        case .protocolEOF: return "Codex connection closed"
        case .protocolTimeout: return "Codex did not respond in time"
        case .protocolRejected: return "Codex rejected the request"
        case .signedOut: return "Codex is not signed in"
        case .missingSupportedField: return "Supported reading is not present"
        case .anthropicCredentialsMissing: return "Local Claude Code sign-in not found"
        case .anthropicCredentialsInvalid: return "Local Claude Code sign-in is unreadable"
        case .anthropicCredentialsExpired: return "Local Claude Code sign-in has expired"
        case .anthropicKeychainDenied: return "Claude Code Keychain access denied"
        case .anthropicAuthRequired: return "Claude Code sign-in required"
        case .anthropicRateLimited: return "Anthropic usage interface is rate limited"
        case .anthropicTimeout: return "Anthropic usage interface timed out"
        case .anthropicNetworkUnavailable: return "Anthropic usage interface unavailable"
        case .anthropicServerUnavailable: return "Anthropic usage interface server unavailable"
        case .anthropicResponseOversized: return "Anthropic returned an oversized response"
        case .anthropicUnknownResponse: return "Anthropic returned no recognized quota windows"
        case .refreshInProgress: return "Refresh in progress"
        case .cancelled: return "Refresh cancelled"
        }
    }
}

enum ReadingState: Equatable {
    case current(UsageObservation)
    case stale(UsageObservation, RedactedIssue)
    case unavailable(RedactedIssue)
    case authRequired(RedactedIssue)
    case unsupported(String)
    case unknown(String)

    var observation: UsageObservation? {
        switch self {
        case .current(let observation), .stale(let observation, _): return observation
        case .unavailable, .authRequired, .unsupported, .unknown: return nil
        }
    }

    var statusName: String {
        switch self {
        case .current: return "current"
        case .stale: return "stale"
        case .unavailable: return "unavailable"
        case .authRequired: return "auth-required"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        }
    }
}

struct ReadingKey: RawRepresentable, Hashable, Codable, Equatable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let codexSession = ReadingKey(rawValue: "codex-session")
    static let codexWeekly = ReadingKey(rawValue: "codex-weekly")
    static let anthropicStatus = ReadingKey(rawValue: "anthropic-status")

    static func anthropic(_ providerID: String) -> ReadingKey {
        ReadingKey(rawValue: "anthropic-" + providerID)
    }
}

struct UsageReading: Identifiable, Equatable {
    let id: ReadingKey
    let provider: Provider
    let title: String
    let scopeDescription: String
    var state: ReadingState
}

struct CodexQuotaReading: Equatable {
    let id: String
    let title: String
    let sourceContainer: String
    let sourceSlot: String
    let observation: UsageObservation
}

struct CodexSnapshot: Equatable {
    let readings: [CodexQuotaReading]

    init(readings: [CodexQuotaReading]) {
        self.readings = readings
    }

    init(session: UsageObservation?, weekly: UsageObservation?) {
        var readings: [CodexQuotaReading] = []
        if let session {
            readings.append(CodexQuotaReading(
                id: "base/session", title: "Codex base session",
                sourceContainer: "fixture", sourceSlot: "session", observation: session
            ))
        }
        if let weekly {
            readings.append(CodexQuotaReading(
                id: "base/weekly", title: "Codex base weekly",
                sourceContainer: "fixture", sourceSlot: "weekly", observation: weekly
            ))
        }
        self.readings = readings
    }

    var session: UsageObservation? {
        readings.first(where: { $0.id == "base/session" })?.observation
    }

    var weekly: UsageObservation? {
        readings.first(where: { $0.id == "base/weekly" })?.observation
    }
}

struct AnthropicQuotaReading: Equatable {
    let key: ReadingKey
    let title: String
    let scopeDescription: String
    let observation: UsageObservation
}

struct AnthropicSnapshot: Equatable {
    let readings: [AnthropicQuotaReading]
}

enum AcquisitionMode: Equatable {
    case live
    case fixture

    var label: String { self == .fixture ? "fixture" : "live" }
}

enum StableIdentifier {
    static func make(from value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func opaqueAccountReference(from value: String) -> String {
        "acct_" + make(from: value)
    }
}
