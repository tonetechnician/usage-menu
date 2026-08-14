import Foundation

/// Where the `codex` executable is, and how we know.
///
/// This exists because the path was previously a compile-time constant naming one developer's
/// home directory and one pinned nvm node version, so the app read nothing on any other Mac and
/// would have read nothing on that one after a node upgrade.
///
/// **The origin is returned alongside the path and is not a debugging nicety.** "We searched and
/// found nothing" and "you told us a path and it is not there" are different states with
/// different remedies, and the product's own rule is that an unreadable signal names itself
/// rather than going quiet. The UI needs the distinction to say something true.
///
/// Every input is injected — environment, home directory, the executable test, and the login
/// shell probe — because a discovery routine that can only be tested by installing software is a
/// discovery routine nobody tests.
struct CodexExecutableDiscovery {
    enum Origin: Equatable {
        /// `--codex-path`, which wins outright: an explicit instruction is not a hint.
        case explicitArgument
        /// `USAGE_MENU_CODEX_PATH`.
        case environmentOverride
        /// A path the user chose in Settings.
        case userPreference
        /// Found on the `PATH` this process actually has.
        case environmentPath
        /// Found by asking the user's login shell, which is the only way to see the `PATH` a
        /// GUI app never inherits.
        case loginShell
        /// Found at a location we know tools install into.
        case knownLocation

        /// True when a human named this path, which is what makes a failure *their* setting
        /// being wrong rather than ours.
        var wasChosenByUser: Bool {
            switch self {
            case .explicitArgument, .environmentOverride, .userPreference: return true
            case .environmentPath, .loginShell, .knownLocation: return false
            }
        }
    }

    struct Outcome: Equatable {
        let path: String?
        let origin: Origin?

        /// What the reading should say when this outcome cannot produce a fetch. Not a
        /// generic error: a user-supplied path that is gone is `executableMissing`, and a
        /// search that came up empty is `executableNotFound`. Sean seeing "Codex executable
        /// unavailable" when he never configured a path told him nothing he could act on.
        var issue: RedactedIssue? {
            guard path == nil else { return nil }
            return origin?.wasChosenByUser == true ? .executableMissing : .executableNotFound
        }
    }

    /// Directories tools put `codex` in, in the order we trust them. Ordering matters only
    /// when several exist, and then the more explicit install wins.
    static func knownDirectories(homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin"
        ]
    }

    /// Resolution, in order, first hit wins.
    ///
    /// A user-named path that does not exist **stops the search** rather than falling through to
    /// discovery. Silently using a different executable than the one someone configured is how a
    /// setting becomes a lie — and with Keychain scoping in play, quietly switching binaries is
    /// not a harmless convenience.
    static func resolve(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: String? = nil,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = Self.isExecutableFile,
        loginShellProbe: () -> String? = Self.probeLoginShell
    ) -> Outcome {
        let named: [(String, Origin)] = [
            (explicitPath, Origin.explicitArgument),
            (environment["USAGE_MENU_CODEX_PATH"], .environmentOverride),
            (preference, .userPreference)
        ].compactMap { value, origin in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (value, origin)
        }

        if let (path, origin) = named.first {
            return Outcome(path: isExecutable(path) ? path : nil, origin: origin)
        }

        let searchDirectories = (environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        for directory in searchDirectories {
            let candidate = "\(directory)/codex"
            if isExecutable(candidate) {
                return Outcome(path: candidate, origin: .environmentPath)
            }
        }

        // Only now the subprocess. A GUI app's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`, so
        // nvm, Homebrew and Volta installs are invisible to the loop above; asking the login
        // shell is the only way to see what the user's terminal sees. It costs a process
        // spawn, which is why it is not first.
        if let probed = loginShellProbe(), isExecutable(probed) {
            return Outcome(path: probed, origin: .loginShell)
        }

        for directory in knownDirectories(homeDirectory: homeDirectory) {
            let candidate = "\(directory)/codex"
            if isExecutable(candidate) {
                return Outcome(path: candidate, origin: .knownLocation)
            }
        }

        // Searched everywhere and found nothing. `origin` is nil because no origin produced
        // this, and `issue` therefore reports `executableNotFound` rather than blaming a
        // setting the user never made.
        return Outcome(path: nil, origin: nil)
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// `$SHELL -lc 'command -v codex'`. Bounded and failure-tolerant: a shell that hangs or a
    /// user with an exotic rc file must degrade to the next strategy, never wedge startup.
    static func probeLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard isExecutableFile(shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v codex"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a login shell that writes more than the pipe buffer would
        // deadlock against `waitUntilExit`, and rc files are exactly the place stray output
        // comes from.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let resolved = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix("/") })
        return resolved
    }
}
