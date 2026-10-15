import Foundation
import Combine

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var error: UsageError?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isReconfiguring = false
    @Published public private(set) var configurationError: UsageError?
    @Published public private(set) var resolvedPath: String?
    @Published public private(set) var customPath: String
    @Published private var running = false

    // Gemini state
    @Published public private(set) var geminiSnapshot: GeminiUsageSnapshot?
    @Published public private(set) var geminiLastUpdated: Date?
    @Published public private(set) var geminiError: UsageError?
    @Published public private(set) var isGeminiRefreshing = false
    @Published public private(set) var agyCustomPath: String

    // Claude state
    @Published public private(set) var claudeSnapshot: ClaudeUsageSnapshot?
    @Published public private(set) var claudeLastUpdated: Date?
    @Published public private(set) var claudeError: UsageError?
    @Published public private(set) var isClaudeRefreshing = false
    @Published public private(set) var claudeCustomPath: String

    // Customization & visibility preferences
    @Published public var showCodexInMenuBar: Bool {
        didSet { defaults.set(showCodexInMenuBar, forKey: "menuBarShowCodex") }
    }
    @Published public var showGeminiInMenuBar: Bool {
        didSet { defaults.set(showGeminiInMenuBar, forKey: "menuBarShowGemini") }
    }
    @Published public var showClaudeInMenuBar: Bool {
        didSet { defaults.set(showClaudeInMenuBar, forKey: "menuBarShowClaude") }
    }
    @Published public var codexLabel: String {
        didSet { defaults.set(codexLabel, forKey: "serviceLabelCodex") }
    }
    @Published public var geminiLabel: String {
        didSet { defaults.set(geminiLabel, forKey: "serviceLabelGemini") }
    }
    @Published public var claudeLabel: String {
        didSet { defaults.set(claudeLabel, forKey: "serviceLabelClaude") }
    }
    @Published public var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode") }
    }

    public let weeklyTracker: WeeklyUsageTracker
    public let geminiWeeklyTracker: WeeklyUsageTracker
    public let claudeWeeklyTracker: WeeklyUsageTracker

    private let client: AppServerConnection
    private let geminiClient: GeminiUsageService
    private let claudeClient: ClaudeUsageService
    private let defaults: UserDefaults
    private let locate: (String) throws -> URL
    private var refreshTask: Task<Void, Never>?
    private var geminiRefreshTask: Task<Void, Never>?
    private var claudeRefreshTask: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var geminiScheduled: Task<Void, Never>?
    private var claudeScheduled: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var epoch = UUID()
    private var lifecycleRevision = 0
    private var disconnectRevision = 0
    private var accountRevision = 0
    private var needsRefresh = false
    private var failures = 0

    public init(client: AppServerConnection? = nil,
                geminiClient: GeminiUsageService? = nil,
                claudeClient: ClaudeUsageService? = nil,
                defaults: UserDefaults = .standard,
                weeklyTracker: WeeklyUsageTracker? = nil,
                geminiWeeklyTracker: WeeklyUsageTracker? = nil,
                claudeWeeklyTracker: WeeklyUsageTracker? = nil,
                locate: @escaping (String) throws -> URL = { try ExecutableLocator.resolve(customPath: $0) }) {
        let legacy = UserDefaults(suiteName: "dev.changjo.CodexUsage")
        let codexPath = defaults.string(forKey: "codexExecutablePath") ?? legacy?.string(forKey: "codexExecutablePath") ?? ""
        let agyPath = defaults.string(forKey: "agyExecutablePath") ?? legacy?.string(forKey: "agyExecutablePath") ?? ""
        let claudePath = defaults.string(forKey: "claudeExecutablePath") ?? legacy?.string(forKey: "claudeExecutablePath") ?? ""
        self.client = client ?? CodexAppServerClient()
        self.geminiClient = geminiClient ?? GeminiAgyClient(customPath: agyPath)
        self.claudeClient = claudeClient ?? ClaudeClient(customPath: claudePath)
        self.defaults = defaults
        self.weeklyTracker = weeklyTracker ?? WeeklyUsageTracker(userDefaults: defaults)
        self.geminiWeeklyTracker = geminiWeeklyTracker ?? WeeklyUsageTracker(userDefaults: defaults, storageKey: "gemini_usage_weekly_tracker")
        self.claudeWeeklyTracker = claudeWeeklyTracker ?? WeeklyUsageTracker(userDefaults: defaults, storageKey: "claude_usage_weekly_tracker")
        self.locate = locate
        self.customPath = codexPath
        self.agyCustomPath = agyPath
        self.claudeCustomPath = claudePath

        self.showCodexInMenuBar = defaults.object(forKey: "menuBarShowCodex") as? Bool ?? legacy?.object(forKey: "menuBarShowCodex") as? Bool ?? true
        self.showGeminiInMenuBar = defaults.object(forKey: "menuBarShowGemini") as? Bool ?? legacy?.object(forKey: "menuBarShowGemini") as? Bool ?? true
        self.showClaudeInMenuBar = defaults.object(forKey: "menuBarShowClaude") as? Bool ?? legacy?.object(forKey: "menuBarShowClaude") as? Bool ?? true
        self.codexLabel = defaults.string(forKey: "serviceLabelCodex") ?? legacy?.string(forKey: "serviceLabelCodex") ?? "Codex"
        self.geminiLabel = defaults.string(forKey: "serviceLabelGemini") ?? legacy?.string(forKey: "serviceLabelGemini") ?? "Gemini"
        self.claudeLabel = defaults.string(forKey: "serviceLabelClaude") ?? legacy?.string(forKey: "serviceLabelClaude") ?? "Claude"
        let modeRaw = defaults.string(forKey: "menuBarDisplayMode") ?? legacy?.string(forKey: "menuBarDisplayMode") ?? MenuBarDisplayMode.both.rawValue
        self.menuBarDisplayMode = MenuBarDisplayMode(rawValue: modeRaw) ?? .both

        if defaults.object(forKey: "menuBarShowCodex") == nil, let val = legacy?.object(forKey: "menuBarShowCodex") as? Bool {
            defaults.set(val, forKey: "menuBarShowCodex")
        }
        if defaults.object(forKey: "menuBarShowGemini") == nil, let val = legacy?.object(forKey: "menuBarShowGemini") as? Bool {
            defaults.set(val, forKey: "menuBarShowGemini")
        }
        if defaults.object(forKey: "menuBarShowClaude") == nil, let val = legacy?.object(forKey: "menuBarShowClaude") as? Bool {
            defaults.set(val, forKey: "menuBarShowClaude")
        }
        if defaults.object(forKey: "serviceLabelCodex") == nil, let val = legacy?.string(forKey: "serviceLabelCodex") {
            defaults.set(val, forKey: "serviceLabelCodex")
        }
        if defaults.object(forKey: "serviceLabelGemini") == nil, let val = legacy?.string(forKey: "serviceLabelGemini") {
            defaults.set(val, forKey: "serviceLabelGemini")
        }
        if defaults.object(forKey: "serviceLabelClaude") == nil, let val = legacy?.string(forKey: "serviceLabelClaude") {
            defaults.set(val, forKey: "serviceLabelClaude")
        }
        if defaults.object(forKey: "menuBarDisplayMode") == nil, let val = legacy?.string(forKey: "menuBarDisplayMode") {
            defaults.set(val, forKey: "menuBarDisplayMode")
        }
        if defaults.object(forKey: "codexExecutablePath") == nil, let val = legacy?.string(forKey: "codexExecutablePath") {
            defaults.set(val, forKey: "codexExecutablePath")
        }
        if defaults.object(forKey: "agyExecutablePath") == nil, let val = legacy?.string(forKey: "agyExecutablePath") {
            defaults.set(val, forKey: "agyExecutablePath")
        }
        if defaults.object(forKey: "claudeExecutablePath") == nil, let val = legacy?.string(forKey: "claudeExecutablePath") {
            defaults.set(val, forKey: "claudeExecutablePath")
        }

        self.client.onNotification = { [weak self] event in self?.notified(event) }
        self.client.onDisconnect = { [weak self] error in
            guard let self, self.running else { return }
            self.disconnectRevision += 1
            self.error = error
            if !self.isRefreshing { self.schedule(after: 60) }
        }
    }

    public var menuBarTitle: String {
        guard running, error == nil else { return "Codex ?" }
        return snapshot?.menuBarTitle ?? (isRefreshing ? "Codex …" : "Codex ?")
    }

    public var menuBarItems: [ProviderUsageItem] {
        var items: [ProviderUsageItem] = []

        if showCodexInMenuBar {
            let val: String
            if let snapshot {
                val = snapshot.formattedValue(for: menuBarDisplayMode)
            } else if isRefreshing {
                val = "…"
            } else if error != nil {
                val = "?"
            } else {
                val = "?"
            }
            items.append(ProviderUsageItem(
                id: "codex",
                label: codexLabel,
                summaryValue: val,
                isRefreshing: isRefreshing,
                hasError: error != nil
            ))
        }

        if showGeminiInMenuBar {
            let val: String
            if let snap = geminiSnapshot {
                val = snap.formattedValue(for: menuBarDisplayMode)
            } else if isGeminiRefreshing {
                val = "…"
            } else if geminiError != nil {
                val = "?"
            } else {
                val = "?"
            }
            items.append(ProviderUsageItem(
                id: "gemini",
                label: geminiLabel,
                summaryValue: val,
                isRefreshing: isGeminiRefreshing,
                hasError: geminiError != nil
            ))
        }

        if showClaudeInMenuBar {
            let val: String
            if let snap = claudeSnapshot {
                val = snap.formattedValue(for: menuBarDisplayMode)
            } else if isClaudeRefreshing {
                val = "…"
            } else if claudeError != nil {
                val = "?"
            } else {
                val = "?"
            }
            items.append(ProviderUsageItem(
                id: "claude",
                label: claudeLabel,
                summaryValue: val,
                isRefreshing: isClaudeRefreshing,
                hasError: claudeError != nil
            ))
        }

        if items.isEmpty {
            let val: String
            if let snapshot {
                val = snapshot.formattedValue(for: menuBarDisplayMode)
            } else if isRefreshing {
                val = "…"
            } else {
                val = "?"
            }
            items.append(ProviderUsageItem(
                id: "codex",
                label: codexLabel,
                summaryValue: val,
                isRefreshing: isRefreshing,
                hasError: error != nil
            ))
        }

        return items
    }

    public func start() {
        guard !running else { return }
        lifecycleRevision += 1
        running = true
        refresh()
    }

    public func refresh() {
        refreshCodex()
        refreshGemini()
        refreshClaude()
    }

    public func refreshCodex() {
        guard running, refreshTask == nil else { return }
        scheduled?.cancel()
        scheduled = nil
        needsRefresh = false
        let current = epoch
        let revision = accountRevision
        let connectionRevision = disconnectRevision
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !client.isConnected {
                    let executable = try locate(customPath)
                    resolvedPath = executable.path
                    try await client.start(executable: executable)
                }
                let response = try await client.readUsage()
                guard epoch == current, !Task.isCancelled else { return }
                guard client.isConnected, disconnectRevision == connectionRevision else {
                    throw self.error ?? UsageError.connectionClosed
                }
                if accountRevision == revision {
                    snapshot = response
                    weeklyTracker.record(snapshot: response)
                    lastUpdated = Date()
                    error = nil
                    failures = 0
                } else {
                    needsRefresh = true
                }
            } catch {
                guard epoch == current, !Task.isCancelled else { return }
                self.error = (error as? UsageError) ?? .requestFailed
                if self.error == .loginRequired || self.error == .unsupportedAccount {
                    snapshot = nil
                    lastUpdated = nil
                }
                failures = min(failures + 1, 4)
                await client.stop()
                guard epoch == current else { return }
            }
            refreshTask = nil
            isRefreshing = false
            // Notifications coalesce; failures always respect backoff even during event bursts.
            let delay = error != nil ? min(300, 60 * pow(2, Double(max(0, failures - 1)))) : (needsRefresh ? 0.5 : 60)
            schedule(after: delay)
        }
    }

    public func stop() async {
        lifecycleRevision += 1
        running = false
        epoch = UUID()
        scheduled?.cancel()
        scheduled = nil
        geminiScheduled?.cancel()
        geminiScheduled = nil
        claudeScheduled?.cancel()
        claudeScheduled = nil
        let previous = refreshTask
        refreshTask = nil
        previous?.cancel()
        geminiRefreshTask?.cancel()
        geminiRefreshTask = nil
        claudeRefreshTask?.cancel()
        claudeRefreshTask = nil
        isRefreshing = false
        isGeminiRefreshing = false
        isClaudeRefreshing = false
        snapshot = nil
        lastUpdated = nil
        claudeSnapshot = nil
        claudeLastUpdated = nil
        needsRefresh = false
        if let cleanup { await cleanup.value; return }
        let operation = Task {
            await client.stop()
            await previous?.value
        }
        cleanup = operation
        await operation.value
        cleanup = nil
    }

    public func refreshGemini() {
        guard running, geminiRefreshTask == nil else { return }
        geminiScheduled?.cancel()
        geminiScheduled = nil
        isGeminiRefreshing = true
        geminiRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snap = try await geminiClient.readUsage()
                guard !Task.isCancelled else { return }
                self.geminiSnapshot = snap
                if let weekly = snap.weeklyBucket, let resetDate = weekly.resetTime {
                    self.geminiWeeklyTracker.record(
                        resetsAt: Int64(resetDate.timeIntervalSince1970),
                        usedPercent: weekly.usedPercent,
                        accountId: "gemini"
                    )
                }
                self.geminiLastUpdated = Date()
                self.geminiError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.geminiError = (error as? UsageError) ?? .requestFailed
            }
            self.isGeminiRefreshing = false
            self.geminiRefreshTask = nil
            self.scheduleGemini(after: 60)
        }
    }

    private func scheduleGemini(after seconds: TimeInterval) {
        guard running else { return }
        geminiScheduled?.cancel()
        geminiScheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            self?.refreshGemini()
        }
    }

    public func applyAgyCustomPath(_ path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        agyCustomPath = trimmed
        defaults.set(trimmed, forKey: "agyExecutablePath")
        if let agyClient = geminiClient as? GeminiAgyClient {
            agyClient.customPath = trimmed
        }
        refreshGemini()
    }

    public func refreshClaude() {
        guard running, claudeRefreshTask == nil else { return }
        claudeScheduled?.cancel()
        claudeScheduled = nil
        isClaudeRefreshing = true
        claudeRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snap = try await claudeClient.readUsage()
                guard !Task.isCancelled else { return }
                self.claudeSnapshot = snap
                if let weekly = snap.sevenDay, let resetDate = weekly.resetsAt {
                    self.claudeWeeklyTracker.record(
                        resetsAt: Int64(resetDate.timeIntervalSince1970),
                        usedPercent: weekly.usedPercent,
                        accountId: "claude"
                    )
                }
                self.claudeLastUpdated = Date()
                self.claudeError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.claudeError = (error as? UsageError) ?? .requestFailed
            }
            self.isClaudeRefreshing = false
            self.claudeRefreshTask = nil
            self.scheduleClaude(after: 60)
        }
    }

    private func scheduleClaude(after seconds: TimeInterval) {
        guard running else { return }
        claudeScheduled?.cancel()
        claudeScheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            self?.refreshClaude()
        }
    }

    public func applyClaudeCustomPath(_ path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeCustomPath = trimmed
        defaults.set(trimmed, forKey: "claudeExecutablePath")
        if let client = claudeClient as? ClaudeClient {
            client.customPath = trimmed
        }
        refreshClaude()
    }

    public func applyCustomPath(_ path: String) async {
        guard !isReconfiguring else { return }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        configurationError = nil
        // Validate explicit paths before stopping a working connection or saving preferences.
        if !trimmedPath.isEmpty {
            do { _ = try locate(trimmedPath) }
            catch {
                configurationError = (error as? UsageError) ?? .cliNotFound
                return
            }
        }
        isReconfiguring = true
        let resumeRevision = lifecycleRevision + 1
        await stop()
        customPath = trimmedPath
        defaults.set(customPath, forKey: "codexExecutablePath")
        resolvedPath = nil
        error = nil
        failures = 0
        isReconfiguring = false
        // A newer sleep/shutdown intent wins over an earlier settings action.
        if lifecycleRevision == resumeRevision { start() }
    }

    private func notified(_ event: AccountNotification) {
        guard running else { return }
        switch event {
        case .accountChanged:
            accountRevision += 1
            snapshot = nil
            lastUpdated = nil
            error = nil
            weeklyTracker.clear()
        case .accountUpdated:
            accountRevision += 1
        case .rateLimitsChanged(let id):
            guard id == nil || id == "codex" else { return }
        }
        needsRefresh = true
        if !isRefreshing { schedule(after: 0.5) }
    }

    private func schedule(after seconds: TimeInterval) {
        guard running else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            self?.refresh()
        }
    }
}
