import Foundation
import XCTest
@testable import UsageMenu

@MainActor
final class AnthropicQuotaTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testFileCredentialSuccessUsesRedirectedClaudeConfig() throws {
        let directory = try temporaryDirectory()
        try writeCredential(["claudeAiOauth": ["accessToken": "fixture-token"]], to: directory)
        let keychain = FakeKeychain(.success(nil))
        let provider = credentialProvider(configDirectory: directory, keychain: keychain)

        _ = try provider.readCredential()

        XCTAssertEqual(keychain.calls.count, 1)
        XCTAssertEqual(provider.credentialFileURL, directory.appendingPathComponent(".credentials.json"))
    }

    func testFileCredentialMissingFallsThroughWithoutRealKeychainAccess() throws {
        let directory = try temporaryDirectory()
        let keychain = FakeKeychain(.success(nil))
        let provider = credentialProvider(configDirectory: directory, keychain: keychain)

        XCTAssertThrowsError(try provider.readCredential()) {
            XCTAssertEqual($0 as? RedactedIssue, .anthropicCredentialsMissing)
        }
        XCTAssertEqual(keychain.calls.count, 1)
    }

    func testFileCredentialMalformedOversizedAndNoTokenAreRejected() throws {
        let cases: [Data] = [
            Data("{not-json".utf8),
            Data(repeating: 0x41, count: 129),
            try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["expiresAt": 123]])
        ]
        for data in cases {
            let directory = try temporaryDirectory()
            try data.write(to: directory.appendingPathComponent(".credentials.json"))
            let provider = credentialProvider(configDirectory: directory, keychain: FakeKeychain(.success(nil)), maximumBytes: 128)
            XCTAssertThrowsError(try provider.readCredential()) {
                XCTAssertEqual($0 as? RedactedIssue, .anthropicCredentialsInvalid)
            }
        }
    }

    func testSnakeCaseFileTokenIsAcceptedBecauseFixtureEstablishesIt() throws {
        let directory = try temporaryDirectory()
        try writeCredential(["claudeAiOauth": ["access_token": "fixture-token"]], to: directory)
        _ = try credentialProvider(configDirectory: directory, keychain: FakeKeychain(.success(nil))).readCredential()
    }

    func testExpiredProviderCredentialRequiresProviderLoginWithoutRefreshingOrPersistingIt() throws {
        let directory = try temporaryDirectory()
        try writeCredential(["claudeAiOauth": [
            "accessToken": "fixture-token",
            "expiresAt": 1_700_000_000
        ]], to: directory)

        XCTAssertThrowsError(try credentialProvider(configDirectory: directory, keychain: FakeKeychain(.success(nil))).readCredential()) {
            XCTAssertEqual($0 as? RedactedIssue, .anthropicCredentialsExpired)
        }
    }

    func testSecondsAndMillisecondsFutureProviderExpiryRemainUsable() throws {
        let directory = try temporaryDirectory()
        for expiry in [2_000_000_000, 2_000_000_000_000] {
            try writeCredential(["claudeAiOauth": ["accessToken": "fixture-token", "expiresAt": expiry]], to: directory)
            _ = try credentialProvider(configDirectory: directory, keychain: FakeKeychain(.success(nil))).readCredential()
        }
    }

    func testInjectedKeychainSuccessMissingAndDenied() throws {
        let directory = try temporaryDirectory()
        let blob = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "keychain-token"]])
        _ = try credentialProvider(configDirectory: directory, keychain: FakeKeychain(.success(blob))).readCredential()

        XCTAssertThrowsError(try credentialProvider(
            configDirectory: directory,
            keychain: FakeKeychain(.success(nil))
        ).readCredential()) {
            XCTAssertEqual($0 as? RedactedIssue, .anthropicCredentialsMissing)
        }
        XCTAssertThrowsError(try credentialProvider(
            configDirectory: directory,
            keychain: FakeKeychain(.failure(RedactedIssue.anthropicKeychainDenied))
        ).readCredential()) {
            XCTAssertEqual($0 as? RedactedIssue, .anthropicKeychainDenied)
        }
    }

    func testKeychainItemWinsOverFileAndNothingIsWrittenUnderClaudeConfig() async throws {
        let directory = try temporaryDirectory()
        try writeCredential(["claudeAiOauth": ["accessToken": "file-token"]], to: directory)
        let blob = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "keychain-token"]])

        let request = try await authorizedRequest(configDirectory: directory, keychain: FakeKeychain(.success(blob)))

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer keychain-token")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [".credentials.json"])
    }

    func testFileIsReadOnlyWhenKeychainHasNoItem() async throws {
        let directory = try temporaryDirectory()
        try writeCredential(["claudeAiOauth": ["accessToken": "file-token"]], to: directory)

        let request = try await authorizedRequest(configDirectory: directory, keychain: FakeKeychain(.success(nil)))

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer file-token")
    }

    func testKeychainDenialStaysDistinctAndNeverFallsBackToFile() async throws {
        let directory = try temporaryDirectory()
        try writeCredential(["claudeAiOauth": ["accessToken": "file-token"]], to: directory)

        let failure = try await sourceFailure(
            configDirectory: directory,
            keychain: FakeKeychain(.failure(RedactedIssue.anthropicKeychainDenied))
        )

        XCTAssertEqual(failure, AnthropicSourceFailure(.anthropicKeychainDenied))
    }

    func testExpiredKeychainTokenRequiresLoginWithoutRequestOrFileFallback() async throws {
        let directory = try temporaryDirectory()
        try writeCredential(["claudeAiOauth": ["accessToken": "file-token", "expiresAt": 2_000_000_000_000]], to: directory)
        let blob = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "keychain-token", "expiresAt": 1_700_000_000_000]
        ])

        let failure = try await sourceFailure(configDirectory: directory, keychain: FakeKeychain(.success(blob)))

        XCTAssertEqual(failure, AnthropicSourceFailure(.anthropicCredentialsExpired))
    }

    func testKeychainQueryPinsServiceAndSafeCurrentAccount() throws {
        let directory = try temporaryDirectory()
        let keychain = FakeKeychain(.success(nil))
        let provider = LocalClaudeCredentialProvider(
            environment: ["CLAUDE_CONFIG_DIR": directory.path, "USER": "fixture-user"],
            homeDirectory: directory,
            keychain: keychain,
            operatingSystemUsername: { "system-user" }
        )
        _ = try? provider.readCredential()
        XCTAssertEqual(keychain.calls.first?.service, "Claude Code-credentials")
        XCTAssertEqual(keychain.calls.first?.account, "fixture-user")
    }

    func testMapsLegacyWindowsAndExtraUsageIndependently() throws {
        let snapshot = try map([
            "five_hour": ["utilization": 18, "resets_at": "2027-01-15T12:00:00Z"],
            "seven_day": ["utilization": 36, "reset_at": "2027-01-20T12:00:00Z"],
            "seven_day_opus": ["utilization": 7, "resets_at": "2027-01-21T12:00:00Z"],
            "extra_usage": ["is_enabled": true, "monthly_limit": 2000, "used_credits": 500, "decimal_places": 2]
        ])

        XCTAssertEqual(snapshot.readings.map(\.key), [.anthropic("five_hour"), .anthropic("seven_day"), .anthropic("seven_day_opus"), .anthropic("extra-usage")])
        XCTAssertEqual(snapshot.readings.map { $0.observation.scope.intervalSeconds }, [18_000, 604_800, 604_800, nil])
        XCTAssertEqual(snapshot.readings[0].observation.remaining, 82)
        XCTAssertEqual(snapshot.readings[3].observation.kind, .cost)
        XCTAssertEqual(snapshot.readings[3].observation.used, 5)
        XCTAssertEqual(snapshot.readings[3].observation.remaining, 15)
        XCTAssertEqual(snapshot.readings[3].observation.scope.unit, .currency)

        let utilizationOnly = try map(["extra_usage": ["is_enabled": true, "utilization": 25]])
        XCTAssertEqual(utilizationOnly.readings.first?.observation.kind, .cost)
        XCTAssertEqual(utilizationOnly.readings.first?.observation.remaining, 75)
        XCTAssertEqual(utilizationOnly.readings.first?.observation.scope.unit, .percent)
    }

    func testPrefersSelfDescribingLimitsAndMapsModelAndUnknownScopes() throws {
        let snapshot = try map([
            "five_hour": ["utilization": 99],
            "limits": [
                ["kind": "session", "group": "session", "percent": 22, "resets_at": "2027-01-15T12:00:00.123Z"],
                ["kind": "weekly_all", "group": "weekly", "percent": 41],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 63,
                 "scope": ["model": ["display_name": "Fable"]]],
                ["kind": "burst_pool", "group": "other", "percent": 11]
            ]
        ])

        XCTAssertEqual(snapshot.readings.map(\.key), [
            .anthropic("five_hour"), .anthropic("seven_day"), .anthropic("model-fable"), .anthropic("limit-burst-pool")
        ])
        XCTAssertEqual(snapshot.readings[0].observation.used, 22)
        XCTAssertEqual(snapshot.readings[2].observation.scope.intervalSeconds, 604_800)
        XCTAssertNil(snapshot.readings[3].observation.scope.intervalSeconds)
        XCTAssertTrue(snapshot.readings[3].scopeDescription.contains("semantics unknown"))
    }

    func testRejectsNonfiniteOutOfRangeAndUnknownSuccessfulShapes() throws {
        for value in [-1.0, 101.0, Double.infinity, Double.nan] {
            XCTAssertNil(AnthropicQuotaMapper.validatedPercent(value))
        }
        for value in [-1.0, 101.0] {
            XCTAssertThrowsError(try map(["five_hour": ["utilization": value]])) {
                XCTAssertEqual($0 as? RedactedIssue, .anthropicUnknownResponse)
            }
        }
        XCTAssertThrowsError(try map(["account": ["email": "private@example.invalid"]])) {
            XCTAssertEqual($0 as? RedactedIssue, .anthropicUnknownResponse)
        }
    }

    func testRequestUsesFixedAnthropicHostAndRequiredHeadersThroughRedactingTransport() async throws {
        let token = "TOKEN_CANARY_" + UUID().uuidString
        let transport = FakeTransport(result: .success(response(status: 200, object: ["five_hour": ["utilization": 12]])))
        let source = AnthropicQuotaSource(credentials: FixedCredential(token), network: transport)

        let snapshot = try await source.fetch()
        let request = try XCTUnwrap(transport.requests.first)

        XCTAssertEqual(request.url, AnthropicQuotaSource.usageURL)
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), AnthropicQuotaSource.betaHeader)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), AnthropicQuotaSource.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(transport.maximumResponseBytes, [256 * 1024])
        XCTAssertFalse(String(describing: snapshot).contains(token))
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().values.contains { String(describing: $0).contains(token) })
    }

    func testTimeout401403429And5xxMapOnlyToAllowlistedFailures() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(Result<AnthropicNetworkResponse, Error>, RedactedIssue)] = [
            (.failure(URLError(.timedOut)), .anthropicTimeout),
            (.failure(RedactedIssue.anthropicResponseOversized), .anthropicResponseOversized),
            (.success(response(status: 401)), .anthropicAuthRequired),
            (.success(response(status: 403)), .anthropicAuthRequired),
            (.success(response(status: 429, retryAfter: "60")), .anthropicRateLimited),
            (.success(response(status: 503)), .anthropicServerUnavailable)
        ]
        for (result, issue) in cases {
            let source = AnthropicQuotaSource(
                credentials: FixedCredential("fixture-token"),
                network: FakeTransport(result: result),
                now: { now }
            )
            do {
                _ = try await source.fetch()
                XCTFail("Expected \(issue.rawValue)")
            } catch let failure as AnthropicSourceFailure {
                XCTAssertEqual(failure.issue, issue)
                if issue == .anthropicRateLimited {
                    XCTAssertEqual(failure.retryAfter, now.addingTimeInterval(60))
                }
            } catch {
                XCTFail("Failure was not redacted")
            }
        }
    }

    func testPrivateResponseFieldsNeverEnterSanitizedObservationOrFailure() async throws {
        let privateCanary = "PRIVATE_RESPONSE_" + UUID().uuidString
        let tokenCanary = "TOKEN_" + UUID().uuidString
        let transport = FakeTransport(result: .success(response(status: 200, object: [
            "five_hour": ["utilization": 12],
            "account": ["email": privateCanary, "uuid": privateCanary],
            "organization": ["id": privateCanary]
        ])))
        let snapshot = try await AnthropicQuotaSource(
            credentials: FixedCredential(tokenCanary), network: transport
        ).fetch()
        let sanitized = String(describing: snapshot)
        XCTAssertFalse(sanitized.contains(privateCanary))
        XCTAssertFalse(sanitized.contains(tokenCanary))
        XCTAssertEqual(snapshot.readings.first?.observation.scope.accountReference, "local_claude_code")
        XCTAssertFalse(snapshot.readings.first?.observation.scope.provenance.contains(privateCanary) == true)
    }

    func testInstalledAnthropicQuotaWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["USAGE_MENU_RUN_ANTHROPIC_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set USAGE_MENU_RUN_ANTHROPIC_LIVE_TESTS=1 to exercise the local Claude Code session")
        }
        let snapshot = try await AnthropicQuotaSource().fetch()
        let knownQuota = snapshot.readings.filter {
            $0.observation.kind == .quota && [18_000, 604_800].contains($0.observation.scope.intervalSeconds)
        }
        XCTAssertFalse(knownQuota.isEmpty, "The redacted live source should expose a known Anthropic quota window")
        let kinds = Set(snapshot.readings.map { $0.observation.kind.rawValue }).sorted().joined(separator: ",")
        XCTContext.runActivity(named: "Anthropic live semantic summary: count=\(snapshot.readings.count), kinds=\(kinds)") { _ in }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UsageMenu-Anthropic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func credentialProvider(
        configDirectory: URL,
        keychain: ClaudeKeychainReading,
        maximumBytes: Int = 64 * 1024
    ) -> LocalClaudeCredentialProvider {
        LocalClaudeCredentialProvider(
            environment: ["CLAUDE_CONFIG_DIR": configDirectory.path, "USER": "fixture-user"],
            homeDirectory: configDirectory,
            keychain: keychain,
            operatingSystemUsername: { "fixture-os-user" },
            maximumCredentialBytes: maximumBytes
        )
    }

    private func authorizedRequest(configDirectory: URL, keychain: ClaudeKeychainReading) async throws -> URLRequest {
        let transport = FakeTransport(result: .success(response(status: 200, object: ["five_hour": ["utilization": 12]])))
        let source = AnthropicQuotaSource(
            credentials: credentialProvider(configDirectory: configDirectory, keychain: keychain),
            network: transport
        )
        _ = try await source.fetch()
        return try XCTUnwrap(transport.requests.first)
    }

    private func sourceFailure(configDirectory: URL, keychain: ClaudeKeychainReading) async throws -> AnthropicSourceFailure? {
        let transport = FakeTransport(result: .success(response(status: 200, object: ["five_hour": ["utilization": 12]])))
        let source = AnthropicQuotaSource(
            credentials: credentialProvider(configDirectory: configDirectory, keychain: keychain),
            network: transport
        )
        do {
            _ = try await source.fetch()
            XCTFail("fetch succeeded")
            return nil
        } catch {
            XCTAssertTrue(transport.requests.isEmpty)
            return error as? AnthropicSourceFailure
        }
    }

    private func writeCredential(_ object: [String: Any], to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: directory.appendingPathComponent(".credentials.json"))
    }

    private func map(_ object: [String: Any]) throws -> AnthropicSnapshot {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try AnthropicQuotaMapper.map(data: data, observedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func response(
        status: Int,
        retryAfter: String? = nil,
        object: [String: Any]? = nil
    ) -> AnthropicNetworkResponse {
        let body = (try? object.map { try JSONSerialization.data(withJSONObject: $0) }) ?? Data()
        return AnthropicNetworkResponse(statusCode: status, retryAfter: retryAfter, body: body)
    }
}

private final class FixedCredential: ClaudeCredentialProviding {
    private let token: String
    init(_ token: String) { self.token = token }
    func readCredential() throws -> ClaudeCredential { ClaudeCredential(accessToken: token) }
}

private final class FakeKeychain: ClaudeKeychainReading {
    struct Call: Equatable { let service: String; let account: String }
    let result: Result<Data?, Error>
    private(set) var calls: [Call] = []
    init(_ result: Result<Data?, Error>) { self.result = result }
    func read(service: String, account: String) throws -> Data? {
        calls.append(Call(service: service, account: account))
        return try result.get()
    }
}

private final class FakeTransport: AnthropicNetworkClient {
    let result: Result<AnthropicNetworkResponse, Error>
    private(set) var requests: [URLRequest] = []
    private(set) var maximumResponseBytes: [Int] = []
    init(result: Result<AnthropicNetworkResponse, Error>) { self.result = result }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AnthropicNetworkResponse {
        requests.append(request)
        self.maximumResponseBytes.append(maximumResponseBytes)
        return try result.get()
    }
    func cancel() {}
}
