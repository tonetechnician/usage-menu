import Darwin
import Foundation

protocol CancellableUsageSource: AnyObject {
    func cancel()
}

protocol CodexUsageSource: CancellableUsageSource {
    func fetch() async throws -> CodexSnapshot
}

struct CodexConfiguration: Equatable {
    /// The issue to report when this configuration cannot produce a fetch, carried from
    /// discovery so the reading can say *why* rather than just that it failed. `nil` means the
    /// executable resolved and any failure will be a real fetch failure.
    let unresolvedIssue: RedactedIssue?

    let executableURL: URL
    let timeout: TimeInterval
    let maximumMessageBytes: Int
    let environment: [String: String]

    init(
        executablePath: String,
        timeout: TimeInterval = 10,
        maximumMessageBytes: Int = 64 * 1024,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        unresolvedIssue: RedactedIssue? = nil
    ) {
        self.unresolvedIssue = unresolvedIssue
        self.executableURL = URL(fileURLWithPath: executablePath)
        self.timeout = timeout
        self.maximumMessageBytes = maximumMessageBytes
        var safeEnvironment = environment
        let executableDirectory = self.executableURL.deletingLastPathComponent().path
        let basePath = safeEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !basePath.split(separator: ":").contains(Substring(executableDirectory)) {
            safeEnvironment["PATH"] = executableDirectory + ":" + basePath
        }
        self.environment = safeEnvironment
    }
}

final class CodexAppServerSource: CodexUsageSource {
    private let configuration: CodexConfiguration
    private let lock = NSLock()
    private var activeClient: CodexProtocolClient?

    init(configuration: CodexConfiguration) {
        self.configuration = configuration
    }

    func fetch() async throws -> CodexSnapshot {
        let client = CodexProtocolClient(configuration: configuration)
        lock.withLock { activeClient = client }
        defer { lock.withLock { activeClient = nil } }

        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try client.fetchSnapshot()
            }.value
        }, onCancel: {
            client.stop()
        })
    }

    func cancel() {
        lock.withLock { activeClient }?.stop()
    }
}

final class CodexProtocolClient: @unchecked Sendable {
    private let configuration: CodexConfiguration
    private let condition = NSCondition()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var terminalIssue: RedactedIssue?
    private var stopped = false

    init(configuration: CodexConfiguration) {
        self.configuration = configuration
    }

    func fetchSnapshot(now: @escaping () -> Date = Date.init) throws -> CodexSnapshot {
        try start()
        defer { stop() }

        _ = try request(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "usage-menu",
                    "title": "Usage Menu",
                    "version": "1"
                ]
            ]
        )
        try send(["method": "initialized"])

        let accountResult = try request(
            id: 2,
            method: "account/read",
            params: ["refreshToken": false]
        )
        let accountReference = try Self.accountReference(from: accountResult)

        let rateLimitResult = try request(
            id: 3,
            method: "account/rateLimits/read",
            params: nil
        )
        return try Self.mapRateLimits(
            result: rateLimitResult,
            accountReference: accountReference,
            observedAt: now()
        )
    }

    private func start() throws {
        let path = configuration.executableURL.path
        // The directory check is load-bearing, not defensive noise. `URL(fileURLWithPath: "")`
        // resolves to the CURRENT DIRECTORY, and `isExecutableFile` answers true for a directory
        // because directories are searchable — so an unresolved path used to sail through this
        // guard and fail later as `processLaunchFailed`, reporting a launch problem for an
        // executable that was never found. A test on the unresolved path caught it.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard configuration.executableURL.isFileURL,
              path.hasPrefix("/"),
              exists, !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else {
            // Discovery's verdict wins when it has one, so a Mac that simply has no `codex`
            // says so instead of implying a broken setting the user never made.
            throw configuration.unresolvedIssue ?? RedactedIssue.executableMissing
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = configuration.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        self.process = process

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.consumeStandardOutput(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            // Drain to prevent backpressure. Protocol and credential-bearing diagnostics are never logged.
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] terminated in
            self?.condition.withLock {
                if terminated.terminationStatus != 0, self?.terminalIssue == nil {
                    self?.terminalIssue = .processExited
                }
                self?.condition.broadcast()
            }
        }

        do {
            try process.run()
        } catch {
            clearHandlers()
            self.process = nil
            throw RedactedIssue.processLaunchFailed
        }
    }

    private func request(id: Int, method: String, params: [String: Any]?) throws -> [String: Any] {
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)

        let deadline = Date().addingTimeInterval(configuration.timeout)
        return try condition.withLock {
            while true {
                if let response = responses.removeValue(forKey: id) {
                    if response["error"] != nil { throw RedactedIssue.protocolRejected }
                    guard let result = response["result"] as? [String: Any] else {
                        throw RedactedIssue.protocolMalformed
                    }
                    return result
                }
                if let terminalIssue { throw terminalIssue }
                if stopped { throw RedactedIssue.cancelled }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { throw RedactedIssue.protocolTimeout }
                _ = condition.wait(until: Date().addingTimeInterval(remaining))
            }
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else {
            throw RedactedIssue.protocolMalformed
        }
        data.append(0x0A)
        do {
            try input?.write(contentsOf: data)
        } catch {
            throw RedactedIssue.protocolEOF
        }
    }

    private func consumeStandardOutput(_ data: Data) {
        condition.withLock {
            guard terminalIssue == nil else { return }
            if data.isEmpty {
                terminalIssue = process?.isRunning == false && process?.terminationStatus != 0
                    ? .processExited : .protocolEOF
                condition.broadcast()
                return
            }
            buffer.append(data)
            guard buffer.count <= configuration.maximumMessageBytes || buffer.contains(0x0A) else {
                terminalIssue = .protocolOversized
                condition.broadcast()
                return
            }

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard line.count <= configuration.maximumMessageBytes else {
                    terminalIssue = .protocolOversized
                    condition.broadcast()
                    return
                }
                guard !line.isEmpty,
                      let value = try? JSONSerialization.jsonObject(with: line),
                      let object = value as? [String: Any] else {
                    terminalIssue = .protocolMalformed
                    condition.broadcast()
                    return
                }
                if let number = object["id"] as? NSNumber {
                    responses[number.intValue] = object
                }
                // Notifications and server requests may interleave with correlated responses.
            }
            if buffer.count > configuration.maximumMessageBytes {
                terminalIssue = .protocolOversized
            }
            condition.broadcast()
        }
    }

    func stop() {
        let ownedProcess: Process? = condition.withLock {
            if stopped { return nil }
            stopped = true
            condition.broadcast()
            return process
        }
        guard let ownedProcess else { return }

        clearHandlers()
        try? input?.close()
        if ownedProcess.isRunning { ownedProcess.terminate() }

        let deadline = Date().addingTimeInterval(1)
        while ownedProcess.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if ownedProcess.isRunning {
            Darwin.kill(ownedProcess.processIdentifier, SIGKILL)
        }
        ownedProcess.waitUntilExit()
        try? output?.close()
        try? errorOutput?.close()
    }

    private func clearHandlers() {
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        process?.terminationHandler = nil
    }

    private static func accountReference(from result: [String: Any]) throws -> String {
        guard let account = result["account"] as? [String: Any] else {
            throw RedactedIssue.signedOut
        }
        let accountType = account["type"] as? String ?? "unknown"
        // The email is used only as in-memory input to a one-way digest and is never retained.
        let privateIdentity = account["email"] as? String
            ?? [accountType, account["planType"] as? String ?? "none"].joined(separator: "|")
        return StableIdentifier.opaqueAccountReference(from: privateIdentity)
    }

    private struct LimitIdentity {
        let namespace: String
        let isKnown: Bool
    }

    private static func limitIdentity(for key: String) -> LimitIdentity {
        let modelPrefix = key.hasPrefix("model:") || key.hasPrefix("codex_") || key.hasPrefix("codex-")
        let modelToken: String
        if key.hasPrefix("model:") {
            modelToken = String(key.dropFirst("model:".count))
        } else if key.hasPrefix("codex_") {
            modelToken = String(key.dropFirst("codex_".count))
        } else if key.hasPrefix("codex-") {
            modelToken = String(key.dropFirst("codex-".count))
        } else {
            modelToken = ""
        }
        if modelPrefix {
            return LimitIdentity(namespace: "model", isKnown: isSafeProviderToken(modelToken))
        }
        let knownWorkloads = Set(["code_review", "code-review"])
        return LimitIdentity(namespace: "workload", isKnown: knownWorkloads.contains(key))
    }

    private static func isSafeProviderToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64, !value.contains("@"), !value.contains("/") else { return false }
        guard value.range(of: "^[A-Za-z][A-Za-z0-9_.:-]*$", options: .regularExpression) != nil else { return false }
        return value.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", options: .regularExpression) == nil
    }

    static func mapRateLimits(
        result: [String: Any],
        accountReference: String,
        observedAt: Date
    ) throws -> CodexSnapshot {
        // Preserve known provider semantics, but never retain an arbitrary
        // provider dictionary key in display data or provenance. Unknown keys
        // receive deterministic labels scoped to this snapshot.
        let named = result["rateLimitsByLimitId"] as? [String: Any]
        var containers: [(sourceContainer: String, label: String, namespace: String, bucket: [String: Any], base: Bool)] = []
        if let named, let codex = named["codex"] as? [String: Any] {
            containers.append(("rateLimitsByLimitId[\"codex\"]", "base", "base", codex, true))
        } else if let topLevel = result["rateLimits"] as? [String: Any] {
            containers.append(("rateLimits", "base", "base", topLevel, true))
        }
        var modelLabel = 0
        var workloadLabel = 0
        if let named {
            for key in named.keys.sorted() where key != "codex" {
                guard let bucket = named[key] as? [String: Any] else { continue }
                let identity = Self.limitIdentity(for: key)
                let label: String
                if identity.isKnown {
                    label = key
                } else if identity.namespace == "model" {
                    modelLabel += 1
                    label = "model-\(modelLabel)"
                } else {
                    workloadLabel += 1
                    label = "workload-\(workloadLabel)"
                }
                let sourceContainer = identity.isKnown
                    ? "rateLimitsByLimitId[\"\(key)\"]"
                    : "rateLimitsByLimitId[redacted-\(label)]"
                containers.append((sourceContainer, label, identity.namespace, bucket, false))
            }
        }

        var readings: [CodexQuotaReading] = []
        for container in containers {
            let candidates: [(slot: String, minutes: Int, used: Double, reset: Date?)] =
                ["primary", "secondary"].compactMap { slot in
                    guard let window = container.bucket[slot] as? [String: Any],
                          let duration = (window["windowDurationMins"] as? NSNumber)?.intValue,
                          let used = (window["usedPercent"] as? NSNumber)?.doubleValue,
                          duration > 0, (0...100).contains(used) else { return nil }
                    let reset = (window["resetsAt"] as? NSNumber)
                        .map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return (slot, duration, used, reset)
                }

            for candidate in candidates {
                let windowKind = candidate.minutes >= 7 * 24 * 60 ? "weekly" : "session"
                let namespace = container.namespace
                let titlePrefix: String
                if container.base {
                    titlePrefix = "Codex base"
                } else if namespace == "model" {
                    titlePrefix = "Codex model \(container.label)"
                } else {
                    titlePrefix = "Codex workload \(container.label)"
                }
                let sourcePath = "account/rateLimits/read:\(container.sourceContainer).\(candidate.slot).usedPercent"
                let resource = "codex-\(namespace)-\(windowKind)" +
                    (container.base ? "" : "-" + container.label)
                let observation = UsageObservation(
                    scope: ObservationScope(
                        provider: .openAI,
                        accountReference: accountReference,
                        productSurface: .consumer,
                        resource: resource,
                        unit: .percent,
                        intervalSeconds: candidate.minutes * 60,
                        provenance: sourcePath
                    ),
                    kind: .rateLimit,
                    used: candidate.used,
                    remaining: 100 - candidate.used,
                    limit: 100,
                    resetAt: candidate.reset,
                    observedAt: observedAt,
                    confidence: .derived
                )
                let id = container.base
                    ? "base/\(windowKind)"
                    : "\(namespace)/\(container.label)/\(windowKind)"
                readings.append(CodexQuotaReading(
                    id: id,
                    title: "\(titlePrefix) \(windowKind)",
                    sourceContainer: container.sourceContainer,
                    sourceSlot: candidate.slot,
                    observation: observation
                ))
            }
        }
        return CodexSnapshot(readings: readings)
    }
}

final class FixtureCodexSource: CodexUsageSource {
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func fetch() async throws -> CodexSnapshot {
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        let account = StableIdentifier.opaqueAccountReference(from: "fixture-account")
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        func make(slot: String, used: Double, minutes: Int, reset: TimeInterval) -> UsageObservation {
            UsageObservation(
                scope: ObservationScope(
                    provider: .openAI,
                    accountReference: account,
                    productSurface: .consumer,
                    resource: "codex-\(slot)",
                    unit: .percent,
                    intervalSeconds: minutes * 60,
                    provenance: "fixture:account/rateLimits/read.\(slot).usedPercent"
                ),
                kind: .rateLimit,
                used: used,
                remaining: 100 - used,
                limit: 100,
                resetAt: Date(timeIntervalSince1970: reset),
                observedAt: observed,
                confidence: .derived
            )
        }
        return CodexSnapshot(
            session: make(slot: "session", used: 82, minutes: 300, reset: 1_800_018_000),
            weekly: make(slot: "weekly", used: 36, minutes: 10_080, reset: 1_800_604_800)
        )
    }

    func cancel() {}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
