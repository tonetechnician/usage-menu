import Foundation
import XCTest
@testable import UsageMenu

final class DiagnosticTests: XCTestCase {
    func testPrivateSourceContainerKeyGetsPerSnapshotLabelInModelAndDiagnosticOutput() throws {
        let privateKey = "model:private-user-\(UUID().uuidString)"
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try CodexProtocolClient.mapRateLimits(
            result: ["rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 6, "windowDurationMins": 10_080]],
                privateKey: ["primary": ["usedPercent": 12, "windowDurationMins": 10_080]]
            ]],
            accountReference: "acct_test",
            observedAt: observed
        )
        let output = RedactedDiagnosticRenderer.render(
            codex: .success(snapshot), anthropic: .success(AnthropicSnapshot(readings: []))
        )

        XCTAssertFalse(String(describing: snapshot).contains(privateKey))
        XCTAssertFalse(String(describing: snapshot).contains("private-user-"))
        XCTAssertFalse(output.contains(privateKey))
        XCTAssertFalse(output.contains("private-user-"))
        XCTAssertTrue(output.contains("window=model/model-1/weekly"))
        XCTAssertTrue(output.contains("title=\"Codex model model-1 weekly\""))
    }

    func testDiagnosticIsSemanticRedactedAndNamesMissingWindows() {
        let canary = "PRIVATE_ACCOUNT_\(UUID().uuidString)"
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = UsageObservation(
            scope: ObservationScope(
                provider: .openAI,
                accountReference: StableIdentifier.opaqueAccountReference(from: canary),
                productSurface: .consumer,
                resource: "codex-base-weekly",
                unit: .percent,
                intervalSeconds: 604_800,
                provenance: "account/rateLimits/read:rateLimits.primary.usedPercent"
            ),
            kind: .rateLimit,
            used: 6,
            remaining: 94,
            limit: 100,
            resetAt: observed.addingTimeInterval(604_800),
            observedAt: observed,
            confidence: .derived
        )
        let output = RedactedDiagnosticRenderer.render(
            codex: .success(CodexSnapshot(readings: [CodexQuotaReading(
                id: "base/weekly", title: "Codex base weekly",
                sourceContainer: "rateLimits", sourceSlot: "primary", observation: observation
            )])),
            anthropic: .success(AnthropicSnapshot(readings: []))
        )

        XCTAssertTrue(output.contains("window=base/weekly"))
        XCTAssertTrue(output.contains("used=6.00% remaining=94.00%"))
        XCTAssertTrue(output.contains("window=base/session"))
        XCTAssertTrue(output.contains("status=unavailable"))
        XCTAssertTrue(output.contains("window=anthropic/five_hour"))
        XCTAssertTrue(output.contains("used=unknown remaining=unknown"))
        XCTAssertFalse(output.contains(canary))
        XCTAssertFalse(output.contains("accountReference"))
        XCTAssertFalse(output.contains("authorization"))
    }
}
