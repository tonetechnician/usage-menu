import Foundation

/// A line-oriented semantic projection for support/debugging. It deliberately has
/// no account, credential, header, or raw-response fields.
struct RedactedDiagnosticRenderer {
    static func render(
        codex: Result<CodexSnapshot, Error>,
        anthropic: Result<AnthropicSnapshot, Error>
    ) -> String {
        var lines: [String] = []
        lines += renderCodex(codex)
        lines += renderAnthropic(anthropic)
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private static func renderCodex(_ result: Result<CodexSnapshot, Error>) -> [String] {
        switch result {
        case .success(let snapshot):
            let expected: [(String, String, Int)] = [
                ("base/session", "Codex base session", 18_000),
                ("base/weekly", "Codex base weekly", 604_800)
            ]
            var rows: [String] = []
            for (id, title, interval) in expected where !snapshot.readings.contains(where: { $0.id == id }) {
                rows.append(missing(provider: "OpenAI", window: id, title: title, interval: interval,
                                    provenance: "account/rateLimits/read:expected-window"))
            }
            rows += snapshot.readings
                .sorted { $0.id < $1.id }
                .map { row(provider: "OpenAI", window: $0.id, title: $0.title, observation: $0.observation) }
            return rows
        case .failure(let error):
            return codexFailureRows(issue: issueName(error))
        }
    }

    private static func renderAnthropic(_ result: Result<AnthropicSnapshot, Error>) -> [String] {
        switch result {
        case .success(let snapshot):
            let expected: [(String, String, Int)] = [
                ("anthropic/five_hour", "Claude session", 18_000),
                ("anthropic/seven_day", "Claude weekly", 604_800),
                ("anthropic/seven_day_opus", "Claude Opus weekly", 604_800)
            ]
            var rows: [String] = []
            for (id, title, interval) in expected where !snapshot.readings.contains(where: { anthropicWindowID($0.key) == id }) {
                rows.append(missing(provider: "Anthropic", window: id, title: title, interval: interval,
                                    provenance: "api/oauth/usage:expected-window"))
            }
            rows += snapshot.readings
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { row(provider: "Anthropic", window: anthropicWindowID($0.key), title: $0.title, observation: $0.observation) }
            return rows
        case .failure(let error):
            let issue = issueName(error)
            let status = [RedactedIssue.anthropicCredentialsMissing.rawValue,
                          RedactedIssue.anthropicCredentialsInvalid.rawValue,
                          RedactedIssue.anthropicKeychainDenied.rawValue,
                          RedactedIssue.anthropicAuthRequired.rawValue].contains(issue)
                ? "auth-required" : "unavailable"
            return [missing(provider: "Anthropic", window: "anthropic/status", title: "Claude quota", interval: nil,
                             provenance: "api/oauth/usage:error-\(issue)", status: status)]
        }
    }

    private static func anthropicWindowID(_ key: ReadingKey) -> String {
        key.rawValue.hasPrefix("anthropic-")
            ? "anthropic/" + String(key.rawValue.dropFirst("anthropic-".count))
            : key.rawValue
    }

    private static func row(provider: String, window: String, title: String, observation: UsageObservation) -> String {
        let interval = observation.scope.intervalSeconds.map { "\($0)s" } ?? "unknown"
        return "provider=\(provider) window=\(safe(window)) title=\"\(safe(title))\" interval=\(interval) " +
            "used=\(percent(observation.used)) remaining=\(percent(observation.remaining)) " +
            "reset=\(date(observation.resetAt)) observed=\(date(observation.observedAt)) " +
            "freshness=current status=current provenance=\(safe(observation.scope.provenance))"
    }

    private static func missing(provider: String, window: String, title: String, interval: Int?, provenance: String,
                                status: String = "unavailable") -> String {
        let intervalText = interval.map { "\($0)s" } ?? "unknown"
        return "provider=\(provider) window=\(safe(window)) title=\"\(safe(title))\" interval=\(intervalText) " +
            "used=unknown remaining=unknown reset=unknown observed=unknown freshness=unknown " +
            "status=\(safe(status)) provenance=\(safe(provenance))"
    }

    private static func codexFailureRows(issue: String) -> [String] {
        let status = issue == RedactedIssue.signedOut.rawValue ? "auth-required" : "unavailable"
        return [
            missing(provider: "OpenAI", window: "base/session", title: "Codex base session", interval: 18_000,
                    provenance: "account/rateLimits/read:error-\(issue)", status: status),
            missing(provider: "OpenAI", window: "base/weekly", title: "Codex base weekly", interval: 604_800,
                    provenance: "account/rateLimits/read:error-\(issue)", status: status)
        ]
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func date(_ value: Date?) -> String {
        guard let value else { return "unknown" }
        return ISO8601DateFormatter.diagnostic.string(from: value)
    }

    private static func issueName(_ error: Error) -> String {
        if let issue = error as? RedactedIssue { return issue.rawValue }
        if let failure = error as? AnthropicSourceFailure { return failure.issue.rawValue }
        return "redacted_error"
    }

    private static func safe(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || "._:/=-[]\" +".unicodeScalars.contains(scalar) {
                return Character(String(scalar))
            }
            return "_"
        }
        return String(scalars.prefix(160))
    }
}

private extension ISO8601DateFormatter {
    static let diagnostic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
