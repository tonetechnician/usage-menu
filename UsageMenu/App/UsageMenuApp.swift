import AppKit
import Foundation
import SwiftUI

/// Opt-in, in-memory live verification for the compact-widget boundary. It emits only elapsed
/// milliseconds and event counts; no provider values, paths, identifiers, or credentials.
enum WidgetOpenMeasurement {
    private static let enabled = ProcessInfo.processInfo.environment["USAGE_MENU_WIDGET_OPEN_MEASUREMENT"] == "1"
    private static let startedAt = ContinuousClock.now
    private static let lock = NSLock()
    private static var widgetOpenCount = 0
    private static var acquisitionAttemptCount = 0

    static func record(_ event: AutomaticRefreshEvent) {
        guard enabled else { return }
        lock.lock()
        switch event {
        case .widgetOpened: widgetOpenCount += 1
        case .acquisitionAttempt: acquisitionAttemptCount += 1
        }
        let elapsed = startedAt.duration(to: .now).components.seconds * 1_000
        let line = "usage-menu-widget-measurement elapsed_ms=\(Int(elapsed)) event=\(event.rawValue) widget_opens=\(widgetOpenCount) acquisition_attempts=\(acquisitionAttemptCount)\n"
        lock.unlock()
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// User-set values that outlive a launch.
///
/// Only the Codex executable path today, and deliberately no UI yet: the settings panel's shape is
/// Sean's open choice (`decisions/20260730-settings-panel-shape-s5d1`), so the storage that the
/// chosen control will write to exists, while the control itself waits for the ruling. Discovery
/// already honours it, so setting the key by hand works in the meantime.
enum UsageMenuPreferences {
    static let codexExecutablePathKey = "codexExecutablePath"

    static var codexExecutablePath: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: codexExecutablePathKey)
            guard let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return stored
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespaces)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: codexExecutablePathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: codexExecutablePathKey)
            }
        }
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowPresentation.observeWindowClosures()
        AppLifecycle.shared.observeApplicationActivation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLifecycle.shared.cancel()
    }
}

final class AppLifecycle {
    static let shared = AppLifecycle()
    private let lock = NSLock()
    private var sources: [CancellableUsageSource] = []
    private var refreshAfterActivation: (() -> Void)?

    func own(_ sources: [CancellableUsageSource]) {
        lock.lock()
        self.sources = sources
        lock.unlock()
    }

    func ownActivationRefresh(_ refresh: @escaping () -> Void) {
        lock.lock()
        refreshAfterActivation = refresh
        lock.unlock()
    }

    func observeApplicationActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.lock.lock()
            let refresh = self?.refreshAfterActivation
            self?.lock.unlock()
            refresh?()
        }
    }

    func cancel() {
        lock.lock()
        let sources = self.sources
        lock.unlock()
        sources.forEach { $0.cancel() }
    }
}

/// Bringing an accessory app's window forward, and lending it a Dock icon while it is up.
///
/// `LSUIElement` is correct for a menu-bar utility and is kept. The cost is that opening a window
/// does not activate the app, so the window appears behind whatever the user was looking at —
/// which is what Sean reported. An accessory app must ask.
///
/// **The Dock icon is transient, deliberately.** A permanent one contradicts the menu-bar design;
/// none at all leaves a window that has slipped behind another app unreachable — absent from
/// Cmd-Tab, absent from the Dock, recoverable only by re-opening from the menu bar. Transient also
/// gives the app a real application menu while a window is up, which is what makes Cmd-Q work.
enum WindowPresentation {
    /// Windows we own and the user can focus. The `MenuBarExtra` panel is an `NSWindow` too and
    /// must not count, or the Dock icon would appear whenever the menu is merely open.
    private static func focusableWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Call after `openWindow(id:)`. Ordering front without activating is not enough for an
    /// accessory app: the window would rise within an app that is still in the background.
    static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            focusableWindows().last?.makeKeyAndOrderFront(nil)
        }
    }

    /// Whether the app should still hold a Dock icon after a window closes.
    ///
    /// Pulled out as a pure function because the off-by-one is the whole risk: `willClose` fires
    /// while the closing window is STILL in `NSApp.windows`, so "the last window is going" reads
    /// as a count of one, not zero. Getting that wrong either strands a Dock icon forever or drops
    /// it while a second window is still open.
    static func shouldKeepDockIcon(focusableWindowCountIncludingClosing count: Int) -> Bool {
        count > 1
    }

    /// Drop back to accessory once the last window closes. Registered once; the notification
    /// fires *before* the window leaves `NSApp.windows`, hence the count of one.
    static func observeWindowClosures() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let closing = notification.object as? NSWindow,
                  closing.canBecomeMain, !(closing is NSPanel) else { return }
            if !shouldKeepDockIcon(focusableWindowCountIncludingClosing: focusableWindows().count) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

private struct UsageMenuBarLabel: View {
    let openDashboardOnLaunch: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var didOpenDashboard = false

    var body: some View {
        Image(systemName: "gauge.with.dots.needle.50percent")
            .accessibilityLabel("Usage Menu")
            .task {
                guard openDashboardOnLaunch, !didOpenDashboard else { return }
                didOpenDashboard = true
                openWindow(id: UsageMenuWindow.dashboard.rawValue)
                WindowPresentation.activate()
            }
    }
}

@main
struct UsageMenuApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var store: UsageStore
    private let openDashboardOnLaunch: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        openDashboardOnLaunch = arguments.contains("--open-dashboard")
        let environment = ProcessInfo.processInfo.environment
        let fixture = arguments.contains("--fixture") || environment["USAGE_MENU_MODE"] == "fixture"

        let codexSource: CodexUsageSource
        let anthropicSource: AnthropicUsageSource
        let mode: AcquisitionMode
        var resolution: CodexExecutableDiscovery.Outcome?
        if fixture {
            codexSource = FixtureCodexSource()
            anthropicSource = FixtureAnthropicSource()
            mode = .fixture
        } else {
            let argumentPath: String? = {
                guard let index = arguments.firstIndex(of: "--codex-path"), arguments.indices.contains(index + 1) else {
                    return nil
                }
                return arguments[index + 1]
            }()
            // Discovery replaces what used to be a hardcoded path to one developer's nvm
            // install. The outcome carries its own issue so a Mac with no `codex` reads
            // "Codex not found on this Mac" rather than implying a broken setting.
            let outcome = CodexExecutableDiscovery.resolve(
                explicitPath: argumentPath,
                environment: environment,
                preference: UsageMenuPreferences.codexExecutablePath
            )
            codexSource = CodexAppServerSource(configuration: CodexConfiguration(
                executablePath: outcome.path ?? "",
                unresolvedIssue: outcome.issue
            ))
            anthropicSource = AnthropicQuotaSource()
            mode = .live
            resolution = outcome
        }

        AppLifecycle.shared.own([codexSource, anthropicSource])

        // Rebuilding lives here rather than in the store because re-taking lifecycle ownership
        // of the replacement source is something only the app can do; a store that swapped its
        // source silently would leave the old process unowned at termination.
        let ownedAnthropic = anthropicSource
        let rebuild: ((CodexExecutableDiscovery.Outcome) -> CodexUsageSource)? = mode == .live
            ? { outcome in
                let replacement = CodexAppServerSource(configuration: CodexConfiguration(
                    executablePath: outcome.path ?? "",
                    unresolvedIssue: outcome.issue
                ))
                AppLifecycle.shared.own([replacement, ownedAnthropic])
                return replacement
            }
            : nil

        let store = UsageStore(
            codexSource: codexSource,
            anthropicSource: anthropicSource,
            mode: mode,
            codexResolution: resolution,
            rebuildCodexSource: rebuild,
            recordAutomaticRefreshEvent: WidgetOpenMeasurement.record
        )
        AppLifecycle.shared.ownActivationRefresh { store.refreshAfterActivation() }
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            CompactMenuView(store: store)
                // The compact MenuBarExtra's visible-content boundary is reliable even when this
                // LSUIElement app stays inactive. The store coalesces recomposition bursts.
                .onAppear { CompactWidgetPresentationBoundary.appeared(store: store) }
        } label: {
            UsageMenuBarLabel(openDashboardOnLaunch: openDashboardOnLaunch)
        }
        .menuBarExtraStyle(.window)

        // `Window`, not `WindowGroup`. `WindowGroup` is the multi-window scene: every
        // `openWindow(id:)` against it creates ANOTHER dashboard, which is exactly the stack of
        // duplicates Sean hit. Settings below was already correct; the dashboard was the outlier.
        Window("Usage Menu Dashboard", id: UsageMenuWindow.dashboard.rawValue) {
            DashboardView(store: store)
        }
        .defaultSize(width: 900, height: 680)
        .windowResizability(.contentMinSize)

        Window("Usage Menu Settings", id: UsageMenuWindow.settings.rawValue) {
            UsageSettingsView(store: store)
        }
        .defaultSize(width: 430, height: 330)
    }
}
