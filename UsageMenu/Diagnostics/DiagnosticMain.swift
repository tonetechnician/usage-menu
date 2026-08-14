import Foundation

@main
struct UsageMenuDiagnostic {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        let fixture = arguments.contains("--fixture")
        // The same discovery the app performs. The diagnostic must resolve the executable the way
        // the product does, or it stops being evidence about the product.
        let outcome = CodexExecutableDiscovery.resolve(
            explicitPath: argument(after: "--codex-path", in: Array(arguments))
        )

        let codex: CodexUsageSource = fixture
            ? FixtureCodexSource()
            : CodexAppServerSource(configuration: CodexConfiguration(
                executablePath: outcome.path ?? "",
                unresolvedIssue: outcome.issue
            ))
        let anthropic: AnthropicUsageSource = fixture
            ? FixtureAnthropicSource()
            : AnthropicQuotaSource()

        async let codexResult = capture { try await codex.fetch() }
        async let anthropicResult = capture { try await anthropic.fetch() }
        let output = RedactedDiagnosticRenderer.render(
            codex: await codexResult,
            anthropic: await anthropicResult
        )
        FileHandle.standardOutput.write(Data(output.utf8))
    }

    private static func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("/") ? value : nil
    }

    private static func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
