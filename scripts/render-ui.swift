// Render the production SwiftUI views with deterministic usage fixtures.
// This validates layout; live UI actions are checked separately with the built app.
import SwiftUI
import AppKit
import CodexUsageCore
import ServiceManagement

@MainActor
final class RenderLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    func register() throws { status = .enabled }
    func unregister() async throws { status = .notRegistered }
    func openSystemSettings() {}
}

@MainActor
final class RenderConnection: AppServerConnection {
    var isConnected = false
    var onNotification: ((AccountNotification) -> Void)?
    var onDisconnect: ((UsageError) -> Void)?
    let response: UsageSnapshot
    let failure: UsageError?
    init(_ response: UsageSnapshot, failure: UsageError? = nil) {
        self.response = response
        self.failure = failure
    }
    func start(executable: URL) async throws { isConnected = true }
    func readUsage() async throws -> UsageSnapshot {
        if let failure { throw failure }
        return response
    }
    func stop() async { isConnected = false }
}

@MainActor
final class RenderGeminiClient: GeminiUsageService {
    func readUsage() async throws -> GeminiUsageSnapshot {
        return GeminiUsageSnapshot(
            groups: [
                GeminiUsageSnapshot.ModelGroup(
                    name: "Gemini Models",
                    description: nil,
                    buckets: [
                        .init(id: "gemini-5h", name: "Pro Session Limit", description: nil, window: "5h", remainingFraction: 0.82, resetTime: Date().addingTimeInterval(3 * 3600)),
                        .init(id: "gemini-weekly", name: "Weekly Limit", description: nil, window: "weekly", remainingFraction: 0.58, resetTime: Date().addingTimeInterval(4 * 86400))
                    ]
                )
            ]
        )
    }
}

@MainActor
final class RenderClaudeClient: ClaudeUsageService {
    func readUsage() async throws -> ClaudeUsageSnapshot {
        return ClaudeUsageSnapshot(
            subscriptionType: "Claude Pro",
            rateLimitsAvailable: true,
            fiveHour: .init(utilization: 28.0, resetsAt: Date().addingTimeInterval(2 * 3600 + 45 * 60)),
            sevenDay: .init(utilization: 64.0, resetsAt: Date().addingTimeInterval(3 * 86400 + 12 * 3600)),
            breakdownRows: [
                .init(key: "claude-3-7-sonnet", displayName: "Claude 3.7 Sonnet", percent: 58.0),
                .init(key: "claude-3-5-haiku", displayName: "Claude 3.5 Haiku", percent: 6.0)
            ]
        )
    }
}

struct Fixture {
    let name: String
    let json: String
    var failure: UsageError? = nil
    var disabled: Set<ProviderKind> = []
    /// Records several days of observations so the weekly histogram renders realistically.
    var weeklyHistory = false
}

@main
struct RenderUI {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/AppIcon.png")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reset = Int(Date.now.addingTimeInterval(2 * 3600 + 13 * 60).timeIntervalSince1970)
        let weeklyReset = reset + 86400 * 3
        let twoLimits = """
        {"rateLimits":{"primary":{"usedPercent":26,"windowDurationMins":300,"resetsAt":\(reset)},"secondary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":\(weeklyReset)},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}},"rateLimitResetCredits":{"availableCount":2}}
        """
        let fixtures = [
            Fixture(name: "two-limits", json: twoLimits, weeklyHistory: true),
            Fixture(name: "low-remaining", json: """
            {"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":\(reset)},"secondary":{"usedPercent":45,"windowDurationMins":10080,"resetsAt":\(weeklyReset)}}}
            """, disabled: [.gemini, .claude]),
            Fixture(name: "weekly-low", json: """
            {"rateLimits":{"primary":{"usedPercent":97,"windowDurationMins":10080,"resetsAt":\(reset)}}}
            """),
            Fixture(name: "no-limits", json: """
            {"rateLimits":{}}
            """),
            Fixture(name: "login-required", json: """
            {"rateLimits":{}}
            """, failure: .loginRequired),
            // A single weekly window keeps the whole popover on screen, so the bottom edge
            // (no trailing divider after the last visible section) is visible in the render.
            Fixture(name: "codex-only", json: """
            {"rateLimits":{"primary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":\(weeklyReset)}}}
            """, disabled: [.gemini, .claude], weeklyHistory: true),
            Fixture(name: "claude-only", json: twoLimits, disabled: [.codex, .gemini]),
            Fixture(name: "no-providers", json: twoLimits, disabled: [.codex, .gemini, .claude])
        ]
        for fixture in fixtures {
            let name = fixture.name
            let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(fixture.json.utf8))
            let client = RenderConnection(snapshot, failure: fixture.failure)
            let suite = "dev.changjo.CodexUsage.render.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let store = UsageStore(
                client: client,
                geminiClient: RenderGeminiClient(),
                claudeClient: RenderClaudeClient(),
                defaults: defaults,
                legacySuiteName: nil,
                locate: { _ in URL(fileURLWithPath: "/opt/homebrew/bin/codex") }
            )
            store.isCodexEnabled = !fixture.disabled.contains(.codex)
            store.isGeminiEnabled = !fixture.disabled.contains(.gemini)
            store.isClaudeEnabled = !fixture.disabled.contains(.claude)
            if fixture.weeklyHistory {
                recordWeeklyHistory(store.weeklyTracker, resetsAt: Int64(weeklyReset))
            }
            store.start()
            for _ in 0..<100 where (store.isRefreshing || store.isGeminiRefreshing || store.isClaudeRefreshing) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                try render(UsagePopover(store: store), name: "\(name)-\(suffix)", dark: dark, output: output)
                if name == "two-limits" {
                    let loginService = RenderLoginItemService()
                    let login = LaunchAtLoginStore(service: loginService)
                    for (tab, tabName) in [(SettingsTab.general, "general"), (.codex, "codex"), (.gemini, "gemini"), (.claude, "claude")] {
                        try render(SettingsView(store: store, launchAtLogin: login, initialTab: tab),
                                   name: "settings-\(tabName)-\(suffix)", dark: dark, output: output)
                    }
                    for (status, stateName) in [(SMAppService.Status.enabled, "enabled"), (.requiresApproval, "approval")] {
                        loginService.status = status
                        login.refreshStatus()
                        try render(SettingsView(store: store, launchAtLogin: login), name: "settings-\(stateName)-\(suffix)", dark: dark, output: output)
                    }
                    let items = store.menuBarItems
                    for count in stride(from: 1, through: items.count, by: 1) {
                        let columns = MenuBarLayout.organizeColumns(items: Array(items.prefix(count)), maxRows: 2)
                        try render(MenuBarSnapshotView(columns: columns).padding(6),
                                   name: "menubar-\(count)-\(suffix)", dark: dark, output: output)
                    }
                    try render(MenuBarGridView(items: []).padding(6), name: "menubar-0-\(suffix)", dark: dark, output: output)
                }
                if name == "codex-only" {
                    let login = LaunchAtLoginStore(service: RenderLoginItemService())
                    try render(SettingsView(store: store, launchAtLogin: login, initialTab: .gemini),
                               name: "settings-gemini-off-\(suffix)", dark: dark, output: output)
                }
            }
            if name == "two-limits" || name == "codex-only" {
                client.isConnected = false
                client.onDisconnect?(.connectionClosed)
                let staleName = name == "two-limits" ? "stale" : "\(name)-stale"
                for dark in [false, true] {
                    let suffix = dark ? "dark" : "light"
                    try render(UsagePopover(store: store), name: "\(staleName)-\(suffix)", dark: dark, output: output)
                    if name == "two-limits" {
                        let login = LaunchAtLoginStore(service: RenderLoginItemService())
                        try render(SettingsView(store: store, launchAtLogin: login, initialTab: .codex),
                                   name: "settings-codex-error-\(suffix)", dark: dark, output: output)
                    }
                }
            }
            await store.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// Simulates a few days of polling (every 3 hours) inside the current weekly cycle.
    @MainActor
    static func recordWeeklyHistory(_ tracker: WeeklyUsageTracker, resetsAt: Int64, now: Date = .now) {
        // Usage added per observation on each calendar day of the cycle.
        let usagePerObservation: [Double] = [0.5, 1.5, 0, 2, 1, 1, 1, 1]
        let calendar = Calendar.current
        let cycleStart = Date(timeIntervalSince1970: TimeInterval(resetsAt)).addingTimeInterval(-WeeklyUsageTracker.cycleDuration)
        let firstDay = calendar.startOfDay(for: cycleStart)
        var used = 0.0
        var time = cycleStart.addingTimeInterval(600)
        while time < now.addingTimeInterval(-3600) {
            tracker.record(resetsAt: resetsAt, usedPercent: used, now: time, calendar: calendar)
            let day = calendar.dateComponents([.day], from: firstDay, to: calendar.startOfDay(for: time)).day ?? 0
            used += usagePerObservation[min(max(0, day), usagePerObservation.count - 1)]
            time.addTimeInterval(3 * 3600)
        }
    }

    @MainActor
    static func render<V: View>(_ view: V, name: String, dark: Bool, output: URL) throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view.environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = NSApp.appearance
        let size = host.fittingSize
        precondition(size.height <= 600, "Popover must keep footer actions on screen")
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        print("\(name): \(Int(size.width)) × \(Int(size.height))")
    }
}
