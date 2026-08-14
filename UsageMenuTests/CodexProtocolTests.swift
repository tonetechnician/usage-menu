import Darwin
import Foundation
import XCTest
@testable import UsageMenu

final class CodexProtocolTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testProtocolCorrelatesRequestsAndMapsIndependentWindows() throws {
        let fixture = try makeFixture(scenario: "normal")
        let client = CodexProtocolClient(configuration: fixture.configuration)
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = try client.fetchSnapshot(now: { observedAt })

        XCTAssertEqual(snapshot.session?.used, 25)
        XCTAssertEqual(snapshot.session?.remaining, 75)
        XCTAssertEqual(snapshot.session?.scope.intervalSeconds, 18_000)
        XCTAssertEqual(snapshot.weekly?.used, 40)
        XCTAssertEqual(snapshot.weekly?.remaining, 60)
        XCTAssertEqual(snapshot.weekly?.scope.intervalSeconds, 604_800)
        XCTAssertNotEqual(snapshot.session?.id, snapshot.weekly?.id)
        XCTAssertEqual(snapshot.session?.observedAt, snapshot.weekly?.observedAt)

        let records = try waitForRecords(at: fixture.recordURL)
        XCTAssertEqual(records.compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "account/read", "account/rateLimits/read"
        ])
        XCTAssertEqual(records.compactMap { ($0["id"] as? NSNumber)?.intValue }, [1, 2, 3])
        assertProcessExited(pidURL: fixture.pidURL)
    }

    func testNamedAndTopLevelRateLimitContainersPreserveWindowIdentityAndProvenance() throws {
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try CodexProtocolClient.mapRateLimits(
            result: [
                "rateLimits": [
                    "primary": ["usedPercent": 6, "windowDurationMins": 10_080]
                ],
                "rateLimitsByLimitId": [
                    "codex": [
                        "primary": ["usedPercent": 6, "windowDurationMins": 10_080]
                    ],
                    "model:codex_bengalfox:7d": [
                        "primary": ["usedPercent": 0, "windowDurationMins": 10_080]
                    ],
                    "code_review": [
                        "primary": ["usedPercent": 10, "windowDurationMins": 300]
                    ]
                ]
            ],
            accountReference: "acct_test",
            observedAt: observed
        )

        XCTAssertEqual(snapshot.weekly?.used, 6)
        XCTAssertTrue(snapshot.readings.contains { $0.id == "model/model:codex_bengalfox:7d/weekly" })
        XCTAssertTrue(snapshot.readings.contains { $0.id == "workload/code_review/session" })
        XCTAssertTrue(snapshot.readings.contains {
            $0.observation.scope.provenance.contains("rateLimitsByLimitId[\"codex\"].primary.usedPercent")
        })
        XCTAssertFalse(snapshot.readings.contains { $0.observation.scope.provenance.contains("rateLimits.primary") })
    }

    func testMalformedMessageIsRedacted() throws {
        try assertFailure(scenario: "malformed", expected: .protocolMalformed)
    }

    func testOversizedMessageIsRejected() throws {
        try assertFailure(scenario: "oversized", maximumBytes: 1024, expected: .protocolOversized)
    }

    func testEOFBeforeResponseIsUnavailableIssue() throws {
        try assertFailure(scenario: "eof", expectedOneOf: [.protocolEOF, .processExited])
    }

    func testNonzeroExitIsRedacted() throws {
        try assertFailure(scenario: "nonzero", expectedOneOf: [.processExited, .protocolEOF])
    }

    func testTimeoutTerminatesChild() throws {
        let fixture = try makeFixture(scenario: "timeout", timeout: 1)
        let client = CodexProtocolClient(configuration: fixture.configuration)
        XCTAssertThrowsError(try client.fetchSnapshot()) { error in
            XCTAssertEqual(error as? RedactedIssue, .protocolTimeout)
        }
        assertProcessExited(pidURL: fixture.pidURL)
    }

    func testMissingExecutableFailsWithoutFixtureFallback() {
        let client = CodexProtocolClient(configuration: CodexConfiguration(executablePath: "/missing/usage-menu-codex"))
        XCTAssertThrowsError(try client.fetchSnapshot()) { error in
            XCTAssertEqual(error as? RedactedIssue, .executableMissing)
        }
    }

    func testCredentialCanaryIsReducedToOpaqueReference() throws {
        let privateCanary = "PRIVATE_VALUE_" + UUID().uuidString
        let fixture = try makeFixture(scenario: "normal", privateValue: privateCanary)
        let snapshot = try CodexProtocolClient(configuration: fixture.configuration).fetchSnapshot()
        let encoded = try JSONEncoder().encode([snapshot.session, snapshot.weekly])
        let applicationOwnedDisplayData = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(applicationOwnedDisplayData.contains(privateCanary))
        XCTAssertTrue(snapshot.session?.scope.accountReference.hasPrefix("acct_") == true)
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().values.contains { String(describing: $0).contains(privateCanary) })
    }

    func testInstalledCodexProtocolWhenExplicitlyEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["USAGE_MENU_RUN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set USAGE_MENU_RUN_LIVE_TESTS=1 to exercise the signed-in local Codex app-server")
        }
        // Discovery, not a hardcoded path — the same resolution the app performs, so this live
        // test exercises what a user actually gets rather than a constant only this machine had.
        guard let path = CodexExecutableDiscovery.resolve(environment: environment).path else {
            throw XCTSkip("No codex executable could be discovered on this machine")
        }
        let snapshot = try CodexProtocolClient(
            configuration: CodexConfiguration(executablePath: path, timeout: 15)
        ).fetchSnapshot()

        let observations = [snapshot.session, snapshot.weekly].compactMap { $0 }
        XCTAssertFalse(observations.isEmpty, "The live source should expose at least one documented Codex window")
        for observation in observations {
            XCTAssertEqual(observation.scope.provider, .openAI)
            XCTAssertEqual(observation.scope.productSurface, .consumer)
            XCTAssertNotNil(observation.used)
            XCTAssertNotNil(observation.remaining)
            XCTAssertNotEqual(observation.scope.accountReference, "")
        }
    }

    private func assertFailure(
        scenario: String,
        maximumBytes: Int = 64 * 1024,
        expected: RedactedIssue
    ) throws {
        try assertFailure(scenario: scenario, maximumBytes: maximumBytes, expectedOneOf: [expected])
    }

    private func assertFailure(
        scenario: String,
        maximumBytes: Int = 64 * 1024,
        expectedOneOf: [RedactedIssue]
    ) throws {
        let fixture = try makeFixture(scenario: scenario, maximumBytes: maximumBytes)
        XCTAssertThrowsError(try CodexProtocolClient(configuration: fixture.configuration).fetchSnapshot()) { error in
            guard let issue = error as? RedactedIssue else {
                return XCTFail("Expected a redacted issue, received \(type(of: error))")
            }
            XCTAssertTrue(expectedOneOf.contains(issue), "Unexpected allowlisted issue: \(issue.rawValue)")
        }
        assertProcessExited(pidURL: fixture.pidURL)
    }

    private struct Fixture {
        let configuration: CodexConfiguration
        let pidURL: URL
        let recordURL: URL
    }

    private func makeFixture(
        scenario: String,
        timeout: TimeInterval = 5,
        maximumBytes: Int = 64 * 1024,
        privateValue: String = "fixture-private-value"
    ) throws -> Fixture {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fake-codex-app-server", withExtension: "py"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UsageMenuTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let executable = directory.appendingPathComponent("fake-codex")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let pidURL = directory.appendingPathComponent("pid")
        let recordURL = directory.appendingPathComponent("requests.json")
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_CODEX_SCENARIO"] = scenario
        environment["FAKE_CODEX_PID_PATH"] = pidURL.path
        environment["FAKE_CODEX_RECORD_PATH"] = recordURL.path
        environment["FAKE_PRIVATE_VALUE"] = privateValue
        return Fixture(
            configuration: CodexConfiguration(
                executablePath: executable.path,
                timeout: timeout,
                maximumMessageBytes: maximumBytes,
                environment: environment
            ),
            pidURL: pidURL,
            recordURL: recordURL
        )
    }

    private func waitForRecords(at url: URL) throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func assertProcessExited(pidURL: URL) {
        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: pidURL.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let value = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(value) else {
            return XCTFail("Fake app-server did not publish its pid")
        }
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Child process \(pid) survived test completion")
        XCTAssertEqual(errno, ESRCH)
    }
}
