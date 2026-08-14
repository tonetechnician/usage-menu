import XCTest
@testable import UsageMenu

/// Discovery replaced a hardcoded path to one developer's nvm install, which is why the app read
/// nothing on any other Mac. These tests pin the two properties that matter: the order, and the
/// refusal to turn a failed lookup into a reassuring reading.
final class CodexDiscoveryTests: XCTestCase {
    private func neverProbes() -> String? {
        XCTFail("the login shell was probed before cheaper strategies were exhausted")
        return nil
    }

    func testExplicitArgumentBeatsEveryOtherStrategy() {
        let outcome = CodexExecutableDiscovery.resolve(
            explicitPath: "/explicit/codex",
            environment: ["USAGE_MENU_CODEX_PATH": "/env/codex", "PATH": "/path"],
            preference: "/preference/codex",
            homeDirectory: "/home",
            isExecutable: { _ in true },
            loginShellProbe: neverProbes
        )
        XCTAssertEqual(outcome.path, "/explicit/codex")
        XCTAssertEqual(outcome.origin, .explicitArgument)
        XCTAssertNil(outcome.issue)
    }

    func testEnvironmentOverrideBeatsPreferenceAndSearch() {
        let outcome = CodexExecutableDiscovery.resolve(
            environment: ["USAGE_MENU_CODEX_PATH": "/env/codex", "PATH": "/path"],
            preference: "/preference/codex",
            homeDirectory: "/home",
            isExecutable: { _ in true },
            loginShellProbe: neverProbes
        )
        XCTAssertEqual(outcome.path, "/env/codex")
        XCTAssertEqual(outcome.origin, .environmentOverride)
    }

    func testPreferenceBeatsSearch() {
        let outcome = CodexExecutableDiscovery.resolve(
            environment: ["PATH": "/path"],
            preference: "/preference/codex",
            homeDirectory: "/home",
            isExecutable: { _ in true },
            loginShellProbe: neverProbes
        )
        XCTAssertEqual(outcome.path, "/preference/codex")
        XCTAssertEqual(outcome.origin, .userPreference)
    }

    /// A configured path that is gone must NOT silently fall through to some other `codex`.
    /// Keychain access is scoped to the signing identity and provider keys are involved; quietly
    /// running a different binary than the one the user named is not a convenience.
    func testUserNamedPathThatIsMissingStopsTheSearchAndBlamesTheSetting() {
        let outcome = CodexExecutableDiscovery.resolve(
            explicitPath: "/gone/codex",
            environment: ["PATH": "/path"],
            homeDirectory: "/home",
            isExecutable: { $0 == "/path/codex" },
            loginShellProbe: neverProbes
        )
        XCTAssertNil(outcome.path, "a user-named path must not fall through to a different binary")
        XCTAssertEqual(outcome.origin, .explicitArgument)
        XCTAssertEqual(outcome.issue, .executableMissing)
    }

    func testProcessPathIsSearchedBeforeSpawningALoginShell() {
        let outcome = CodexExecutableDiscovery.resolve(
            environment: ["PATH": "/first:/second"],
            homeDirectory: "/home",
            isExecutable: { $0 == "/second/codex" },
            loginShellProbe: neverProbes
        )
        XCTAssertEqual(outcome.path, "/second/codex")
        XCTAssertEqual(outcome.origin, .environmentPath)
    }

    /// The case that actually broke on Sean's Mac: a Finder-launched app gets a minimal `PATH`,
    /// so an nvm/Homebrew install is invisible until the login shell is asked.
    func testLoginShellFindsWhatAGuiProcessPathCannotSee() {
        let outcome = CodexExecutableDiscovery.resolve(
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            homeDirectory: "/test-home",
            isExecutable: { $0 == "/test-home/tools/codex" },
            loginShellProbe: { "/test-home/tools/codex" }
        )
        XCTAssertEqual(outcome.path, "/test-home/tools/codex")
        XCTAssertEqual(outcome.origin, .loginShell)
    }

    func testKnownLocationsAreTriedWhenTheShellCannotHelp() {
        let outcome = CodexExecutableDiscovery.resolve(
            environment: ["PATH": "/usr/bin"],
            homeDirectory: "/home",
            isExecutable: { $0 == "/opt/homebrew/bin/codex" },
            loginShellProbe: { nil }
        )
        XCTAssertEqual(outcome.path, "/opt/homebrew/bin/codex")
        XCTAssertEqual(outcome.origin, .knownLocation)
    }

    /// The honesty rule, stated as a test. Nothing found means nothing found — and it is
    /// distinguishable from a broken setting, because "Codex not found on this Mac" is actionable
    /// and "your configured path is wrong" would be a lie when no path was ever configured.
    func testNothingFoundAnywhereReportsNotFoundRatherThanBlamingASettingOrReturningAValue() {
        let outcome = CodexExecutableDiscovery.resolve(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: "/home",
            isExecutable: { _ in false },
            loginShellProbe: { nil }
        )
        XCTAssertNil(outcome.path)
        XCTAssertNil(outcome.origin)
        XCTAssertEqual(outcome.issue, .executableNotFound)
        XCTAssertNotEqual(outcome.issue, .executableMissing)
    }

    /// A resolved executable carries no issue: a later failure must be reported as the real fetch
    /// failure it is, not as a discovery problem.
    func testResolvedOutcomeCarriesNoIssue() {
        let outcome = CodexExecutableDiscovery.resolve(
            environment: ["PATH": "/usr/bin"],
            homeDirectory: "/home",
            isExecutable: { _ in true },
            loginShellProbe: neverProbes
        )
        XCTAssertNotNil(outcome.path)
        XCTAssertNil(outcome.issue)
    }

    func testBlankUserSuppliedPathsAreIgnoredRatherThanTreatedAsAChoice() {
        let outcome = CodexExecutableDiscovery.resolve(
            explicitPath: "   ",
            environment: ["USAGE_MENU_CODEX_PATH": "", "PATH": "/usr/bin"],
            preference: "",
            homeDirectory: "/home",
            isExecutable: { $0 == "/usr/bin/codex" },
            loginShellProbe: neverProbes
        )
        XCTAssertEqual(outcome.path, "/usr/bin/codex")
        XCTAssertEqual(outcome.origin, .environmentPath)
    }

    /// The unresolved issue reaches the source rather than being computed twice, so what the UI
    /// says and what discovery concluded cannot drift apart.
    func testConfigurationCarriesDiscoverysIssueToTheSource() async {
        let source = CodexAppServerSource(configuration: CodexConfiguration(
            executablePath: "",
            unresolvedIssue: .executableNotFound
        ))
        do {
            _ = try await source.fetch()
            XCTFail("an unresolved executable must not produce a snapshot")
        } catch {
            XCTAssertEqual(error as? RedactedIssue, .executableNotFound)
        }
    }
}
