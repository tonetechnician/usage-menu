import AppKit
import SwiftUI

enum UsageMenuWindow: String, Equatable {
    case dashboard
    case settings
}

enum CompactMenuAction: Equatable {
    case settings
    case openDashboard

    var destination: UsageMenuWindow {
        switch self {
        case .settings: return .settings
        case .openDashboard: return .dashboard
        }
    }
}

struct CompactMenuView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow

    var resolvedStoreIdentifier: UUID { store.instanceIdentifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage Menu").font(.headline)
                    Text(UsageAccessibility.freshnessText(for: store.lastAttemptAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .accessibilityLabel(store.isRefreshing ? "Refreshing readings" : "Refresh readings")
                .accessibilityIdentifier("menu-refresh")
            }

            ProviderGroup(
                title: "OpenAI",
                subtitle: "Codex",
                readings: store.readings.filter { $0.provider == .openAI },
                compact: true,
                identifierPrefix: "menu",
                sourceDescription: "Codex app-server · local documented source"
            )
            ProviderGroup(
                title: "Anthropic",
                subtitle: "Claude",
                readings: store.readings.filter { $0.provider == .anthropic },
                compact: true,
                identifierPrefix: "menu",
                sourceDescription: "Local Claude Code · undocumented provider-owned OAuth usage interface"
            )

            Divider()
            HStack {
                Button("Settings") {
                    openWindow(id: CompactMenuAction.settings.destination.rawValue)
                    WindowPresentation.activate()
                }
                .accessibilityIdentifier("menu-settings")
                Spacer()
                Button("Open Dashboard") {
                    openWindow(id: CompactMenuAction.openDashboard.destination.rawValue)
                    WindowPresentation.activate()
                }
                    .accessibilityIdentifier("open-dashboard")
                Spacer()
                // A window-style MenuBarExtra gets no application menu, so an accessory app
                // has no Quit unless one is put here. Cmd-Q alone would not do: a key
                // equivalent needs a key window and this app often has none. The visible
                // item is the load-bearing half.
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityIdentifier("menu-quit")
                .accessibilityLabel("Quit Usage Menu")
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .controlSize(.small)
        }
        .padding(14)
        .frame(minWidth: 320)
        .task { await store.refreshOnStartupIfNeeded() }
    }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow

    var resolvedStoreIdentifier: UUID { store.instanceIdentifier }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your limits")
                            .font(.largeTitle.weight(.bold))
                            .accessibilityIdentifier("dashboard-title")
                        Text("What you can still use, ordered by provider.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(UsageAccessibility.freshnessText(for: store.lastAttemptAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                Task { await store.refresh() }
                            } label: {
                                Label(store.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                            }
                            .disabled(store.isRefreshing)
                            .accessibilityLabel(store.isRefreshing ? "Refreshing readings" : "Refresh readings")
                            .accessibilityIdentifier("dashboard-refresh")
                            Button("Settings") {
                                openWindow(id: UsageMenuWindow.settings.rawValue)
                                WindowPresentation.activate()
                            }
                            .accessibilityIdentifier("dashboard-settings")
                        }
                    }
                }

                ProviderGroup(
                    title: "OpenAI",
                    subtitle: "Codex",
                    readings: store.readings.filter { $0.provider == .openAI },
                    compact: false,
                    identifierPrefix: "dashboard",
                    sourceDescription: "Codex app-server · local documented source"
                )
                .accessibilityIdentifier("provider-openai")

                ProviderGroup(
                    title: "Anthropic",
                    subtitle: "Claude",
                    readings: store.readings.filter { $0.provider == .anthropic },
                    compact: false,
                    identifierPrefix: "dashboard",
                    sourceDescription: "Local Claude Code · undocumented provider-owned OAuth usage interface"
                )
                .accessibilityIdentifier("provider-anthropic")

                HStack {
                    Text("Weekly is shown first. A 5-hour reading appears only when that provider returns it.")
                    Spacer()
                    Button("Settings") {
                        openWindow(id: UsageMenuWindow.settings.rawValue)
                        WindowPresentation.activate()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 540, minHeight: 420)
        .task { await store.refreshOnStartupIfNeeded() }
    }
}

private struct ProviderGroup: View {
    let title: String
    let subtitle: String
    let readings: [UsageReading]
    let compact: Bool
    let identifierPrefix: String
    let sourceDescription: String

    private var visibleReadings: [UsageReading] {
        UsageAccessibility.visibleReadings(from: readings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(title == "OpenAI" ? Color.teal : Color.orange)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if visibleReadings.isEmpty {
                Text("No readings returned")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(compact ? 10 : 16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
            } else if compact {
                VStack(spacing: 8) {
                    ForEach(visibleReadings) {
                        ReadingCard(reading: $0, compact: true, identifierPrefix: identifierPrefix)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(visibleReadings) {
                        ReadingCard(reading: $0, compact: false, identifierPrefix: identifierPrefix)
                    }
                }
            }

            SourceDetails(
                sourceDescription: sourceDescription,
                readings: readings,
                compact: compact
            )
        }
    }
}

private struct SourceDetails: View {
    let sourceDescription: String
    let readings: [UsageReading]
    let compact: Bool

    var body: some View {
        DisclosureGroup("Source details") {
            VStack(alignment: .leading, spacing: 8) {
                Text(sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(readings) { reading in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(UsageAccessibility.windowTitle(for: reading))
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(reading.state.statusName)
                                .font(.caption2.weight(.semibold))
                        }
                        Text(UsageAccessibility.sourceSummary(for: reading))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let used = UsageAccessibility.usedText(for: reading) {
                            Text(used)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Advanced") {
                            AdvancedDetails(reading: reading)
                        }
                        .font(.caption2)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(.top, 5)
        }
        .font(compact ? .caption2 : .caption)
        .accessibilityLabel("Source details, \(sourceDescription), \(readings.map(UsageAccessibility.sourceSummary(for:)).joined(separator: "; "))")
        .accessibilityHint("Reveals source status and optional technical evidence")
    }
}

private struct AdvancedDetails: View {
    let reading: UsageReading

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let observation = reading.state.observation {
                Text("Observation ID: \(observation.id)")
                Text("Provenance: \(observation.scope.provenance)")
                Text("Interval: \(observation.scope.intervalSeconds.map(String.init) ?? "unknown") seconds")
                Text("Observed: \(UsageAccessibility.timestamp.string(from: observation.observedAt))")
            } else {
                Text("No observation evidence is available.")
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(.top, 3)
    }
}

private struct ReadingCard: View {
    let reading: UsageReading
    let compact: Bool
    let identifierPrefix: String

    var body: some View {
        HStack(spacing: 14) {
            stateVisual
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(UsageAccessibility.windowTitle(for: reading))
                        .font(compact ? .subheadline.weight(.semibold) : .headline.weight(.semibold))
                    Spacer()
                    StatusBadge(name: reading.state.statusName)
                }
                Text(UsageAccessibility.primaryText(for: reading))
                    .font(compact ? .body.weight(.semibold) : .title3.weight(.bold))
                Text(UsageAccessibility.secondaryText(for: reading))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, minHeight: compact ? 78 : 122, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.quaternary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageAccessibility.label(for: reading))
        .accessibilityIdentifier("\(identifierPrefix)-reading-\(reading.id.rawValue)")
    }

    @ViewBuilder private var stateVisual: some View {
        if let observation = reading.state.observation,
           observation.scope.unit == .percent,
           let remaining = observation.remaining {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(0, min(1, remaining / 100)))
                    .stroke(reading.provider == .openAI ? Color.teal : Color.orange,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded()))%")
                    .font(.caption2.bold())
            }
            .frame(width: compact ? 52 : 68, height: compact ? 52 : 68)
            .accessibilityHidden(true)
        } else {
            Image(systemName: UsageAccessibility.stateIcon(for: reading))
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: compact ? 52 : 68, height: compact ? 52 : 68)
                .background(Color.secondary.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
        }
    }
}

enum UsageAccessibility {
    static func primaryText(for reading: UsageReading) -> String {
        switch reading.state {
        case .current(let observation), .stale(let observation, _):
            if observation.scope.unit == .currency {
                if let remaining = observation.remaining { return String(format: "$%.2f remaining", remaining) }
                if let used = observation.used { return String(format: "$%.2f used", used) }
            }
            if let remaining = observation.remaining { return "\(Int(remaining.rounded()))% remaining" }
            if let used = observation.used { return "\(Int(used.rounded()))% used" }
            return "Value unknown"
        case .unavailable: return "Unavailable"
        case .authRequired: return "Sign-in required"
        case .unsupported: return "Unsupported"
        case .unknown: return "Unknown"
        }
    }

    static func secondaryText(for reading: UsageReading) -> String {
        switch reading.state {
        case .current(let observation): return detail(observation: observation, prefix: "Current")
        case .stale(let observation, let issue):
            return detail(observation: observation, prefix: "Stale · \(issue.displayText)")
        case .unavailable(let issue), .authRequired(let issue):
            return issue.displayText
        case .unsupported(let reason), .unknown(let reason):
            return reason
        }
    }

    static func label(for reading: UsageReading) -> String {
        let freshness: String
        if let observation = reading.state.observation {
            freshness = "observed \(timestamp.string(from: observation.observedAt))"
        } else {
            freshness = "observation time unavailable"
        }
        return "\(reading.provider.rawValue), \(windowTitle(for: reading)), \(primaryText(for: reading)), \(secondaryText(for: reading)), \(freshness), state \(reading.state.statusName)"
    }

    static func freshnessText(for date: Date?) -> String {
        guard let date else { return "Not refreshed" }
        return "Updated \(timestamp.string(from: date))"
    }

    static func windowTitle(for reading: UsageReading) -> String {
        if isFiveHour(reading) { return "5-hour" }
        let title = reading.title
        let lower = title.lowercased()
        guard lower.contains("weekly") else { return title }
        var cleaned = title
            .replacingOccurrences(of: " weekly", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "weekly ", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.lowercased().hasPrefix("claude ") {
            cleaned = String(cleaned.dropFirst("Claude ".count))
        }
        if cleaned.isEmpty || cleaned.caseInsensitiveCompare("Codex") == .orderedSame || cleaned.caseInsensitiveCompare("Claude") == .orderedSame {
            return "Weekly"
        }
        return "\(cleaned) · Weekly"
    }

    static func visibleReadings(from readings: [UsageReading]) -> [UsageReading] {
        readings
            .filter { !isFiveHour($0) || $0.state.observation != nil }
            .sorted { windowPriority(for: $0) < windowPriority(for: $1) }
    }

    static func isFiveHour(_ reading: UsageReading) -> Bool {
        let lower = reading.title.lowercased()
        return reading.id == .codexSession || lower.contains("session") ||
            reading.state.observation?.scope.intervalSeconds == 18_000
    }

    static func windowPriority(for reading: UsageReading) -> Int {
        let lower = reading.title.lowercased()
        if reading.id == .codexWeekly || lower == "claude weekly" || lower == "codex weekly" {
            return 0
        }
        if isFiveHour(reading) { return 1 }
        if lower.contains("weekly") || reading.state.observation?.scope.intervalSeconds == 604_800 {
            return 2
        }
        return reading.id == .anthropicStatus ? 3 : 2
    }

    static func sourceSummary(for reading: UsageReading) -> String {
        switch reading.state {
        case .current: return "Current · \(reading.scopeDescription)"
        case .stale(_, let issue): return "Stale · \(issue.displayText)"
        case .unavailable(let issue): return "Unavailable · \(issue.displayText)"
        case .authRequired(let issue): return "Auth required · \(issue.displayText)"
        case .unsupported(let reason): return "Unsupported · \(reason)"
        case .unknown(let reason): return "Unknown · \(reason)"
        }
    }

    static func usedText(for reading: UsageReading) -> String? {
        guard let used = reading.state.observation?.used else { return nil }
        if reading.state.observation?.scope.unit == .currency {
            return String(format: "Used $%.2f", used)
        }
        return "Used \(Int(used.rounded()))%"
    }

    static func stateIcon(for reading: UsageReading) -> String {
        switch reading.state {
        case .current: return "checkmark.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .unavailable: return "exclamationmark.triangle"
        case .authRequired: return "person.crop.circle.badge.exclamationmark"
        case .unsupported: return "nosign"
        case .unknown: return "questionmark.circle"
        }
    }

    private static func detail(observation: UsageObservation, prefix: String) -> String {
        let reset = observation.resetAt.map { "resets \(timestamp.string(from: $0))" } ?? "reset unknown"
        return "\(prefix) · \(reset) · observed \(timestamp.string(from: observation.observedAt))"
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct StatusBadge: View {
    let name: String

    var body: some View {
        Text(name.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .accessibilityLabel("Status \(name)")
    }
}

/// What Settings says about the Codex executable, as pure functions.
///
/// Pulled out of the view because these are the sentences that must not lie, and a sentence
/// only assembled inside a `body` can only be checked by looking at it. The failure case is the
/// one that matters here — it is the state Sean actually hit.
enum SettingsPresentation {
    /// The badge. Three states, not two: fixture mode is neither resolved nor broken.
    static func codexStatusLabel(for outcome: CodexExecutableDiscovery.Outcome?) -> String {
        guard let outcome else { return "Not applicable" }
        if outcome.path != nil { return "Resolved" }
        return outcome.issue == .executableMissing ? "Path is gone" : "Not found"
    }

    static func codexIsResolved(_ outcome: CodexExecutableDiscovery.Outcome?) -> Bool {
        outcome?.path != nil
    }

    /// The path row. Never an empty string pretending to be a path.
    static func codexPathText(for outcome: CodexExecutableDiscovery.Outcome?) -> String {
        guard let outcome else { return "Fixture mode — no executable is used" }
        return outcome.path ?? "No executable"
    }

    /// Where it came from, in the user's terms rather than the enum's.
    static func codexOriginText(for outcome: CodexExecutableDiscovery.Outcome?) -> String? {
        guard let outcome, outcome.path != nil, let origin = outcome.origin else { return nil }
        switch origin {
        case .explicitArgument: return "Set by a launch argument"
        case .environmentOverride: return "Set by USAGE_MENU_CODEX_PATH"
        case .userPreference: return "Chosen by you"
        case .environmentPath: return "Found on PATH"
        case .loginShell: return "Found by asking your login shell"
        case .knownLocation: return "Found in a known install location"
        }
    }

    /// The consequence, stated plainly. This is the product's own rule written into the UI: an
    /// unreadable provider says so and stays unavailable, and is never softened into a zero.
    static func codexConsequenceText(for outcome: CodexExecutableDiscovery.Outcome?) -> String? {
        guard let outcome, outcome.path == nil else { return nil }
        let cause = outcome.issue == .executableMissing
            ? "The path that was set no longer exists."
            : "Discovery searched every location below and found nothing."
        return cause + " OpenAI readings stay unavailable until a valid path is set — "
            + "they are never shown as zero or current."
    }

    /// What was actually tried, so "not found" is checkable rather than merely asserted.
    static func searchedLocations(homeDirectory: String = NSHomeDirectory()) -> [String] {
        ["Your PATH", "Your login shell"]
            + CodexExecutableDiscovery.knownDirectories(homeDirectory: homeDirectory)
                .map { $0 + "/codex" }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (build \(build))"
    }
}

/// Option A — "minimal preferences". Settings holds ONLY controls that do something.
///
/// What was here before was three `Form` sections of static prose, two of which admitted in so
/// many words that the feature they described did not exist yet. Those are deleted rather than
/// restyled: a setting that does nothing should not be shown, and an apology is not a control.
struct UsageSettingsView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    private var outcome: CodexExecutableDiscovery.Outcome? { store.codexResolution }
    private var resolved: Bool { SettingsPresentation.codexIsResolved(outcome) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings-done")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    codexGroup
                    sourcesGroup
                    aboutGroup
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 460, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var codexGroup: some View {
        SettingsGroup(title: "Codex Executable") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SettingsPresentation.codexPathText(for: outcome))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings-codex-path")
                SettingsStatusBadge(text: SettingsPresentation.codexStatusLabel(for: outcome), ok: resolved)
            }

            if let origin = SettingsPresentation.codexOriginText(for: outcome) {
                Text(origin).font(.caption).foregroundStyle(.secondary)
            }

            if let consequence = SettingsPresentation.codexConsequenceText(for: outcome) {
                Text(consequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-codex-consequence")

                DisclosureGroup("Where it looked") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SettingsPresentation.searchedLocations(), id: \.self) { location in
                            Text(location)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }

            if store.mode == .live {
                HStack {
                    Button("Choose…") { chooseExecutable() }
                        .accessibilityIdentifier("settings-codex-choose")
                    Button("Detect Again") {
                        isWorking = true
                        Task { await store.redetectCodexExecutable(); isWorking = false }
                    }
                    .accessibilityIdentifier("settings-codex-redetect")
                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(isWorking)
                .padding(.top, 2)

                Text("Detect Again clears the path you chose and searches from scratch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourcesGroup: some View {
        SettingsGroup(title: "Sources") {
            ForEach(providerSummaries, id: \.name) { summary in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(summary.name.hasPrefix("OpenAI") ? Color.teal : Color.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary.name).font(.callout)
                        Text(summary.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(summary.state).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aboutGroup: some View {
        SettingsGroup(title: "About") {
            HStack {
                Text("Usage Menu").font(.callout)
                Spacer()
                Text(SettingsPresentation.appVersion).font(.caption).foregroundStyle(.secondary)
            }
            Text("Refresh is manual — use Refresh on Your limits. Per-provider technical evidence "
                 + "lives under Source details there.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct ProviderSummary { let name: String; let detail: String; let state: String }

    private var providerSummaries: [ProviderSummary] {
        let openAI = UsageAccessibility.visibleReadings(
            from: store.readings.filter { $0.provider == .openAI })
        let anthropic = UsageAccessibility.visibleReadings(
            from: store.readings.filter { $0.provider == .anthropic })
        return [
            ProviderSummary(
                name: "OpenAI · Codex",
                detail: "Local documented Codex app-server",
                state: openAI.first.map { $0.state.statusName.capitalized } ?? "No readings"
            ),
            ProviderSummary(
                name: "Anthropic · Claude",
                detail: "Local Claude Code · undocumented provider-owned interface",
                state: anthropic.first.map { $0.state.statusName.capitalized } ?? "No readings"
            )
        ]
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the codex executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        Task { await store.chooseCodexExecutable(path: url.path); isWorking = false }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
        }
    }
}

private struct SettingsStatusBadge: View {
    let text: String
    let ok: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((ok ? Color.green : Color.orange).opacity(0.16))
            )
            // Never colour alone: the word carries the state for anyone who cannot see the hue.
            .foregroundStyle(ok ? Color.green : Color.orange)
            .fixedSize()
    }
}
