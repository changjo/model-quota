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
    @Published public private(set) var geminiConfigurationError: UsageError?
    @Published public private(set) var geminiResolvedPath: String?

    // Claude state
    @Published public private(set) var claudeSnapshot: ClaudeUsageSnapshot?
    @Published public private(set) var claudeLastUpdated: Date?
    @Published public private(set) var claudeError: UsageError?
    @Published public private(set) var isClaudeRefreshing = false
    @Published public private(set) var claudeCustomPath: String
    @Published public private(set) var claudeConfigurationError: UsageError?
    @Published public private(set) var claudeResolvedPath: String?

    // Provider enablement: a disabled provider is hidden everywhere and never polled.
    @Published public var isCodexEnabled: Bool {
        didSet { providerEnablementChanged(.codex, from: oldValue, to: isCodexEnabled) }
    }
    @Published public var isGeminiEnabled: Bool {
        didSet { providerEnablementChanged(.gemini, from: oldValue, to: isGeminiEnabled) }
    }
    @Published public var isClaudeEnabled: Bool {
        didSet { providerEnablementChanged(.claude, from: oldValue, to: isClaudeEnabled) }
    }

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
    // Popover visibility only removes a section; the provider is still polled and shown in the menu bar.
    @Published public var showCodexInPopover: Bool {
        didSet { defaults.set(showCodexInPopover, forKey: "popoverShowCodex") }
    }
    @Published public var showGeminiInPopover: Bool {
        didSet { defaults.set(showGeminiInPopover, forKey: "popoverShowGemini") }
    }
    @Published public var showClaudeInPopover: Bool {
        didSet { defaults.set(showClaudeInPopover, forKey: "popoverShowClaude") }
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
    /// Menu bar cells fill in this order; the popover has its own order.
    /// Assigning an unnormalized order re-enters `didSet` exactly once: normalizing is idempotent,
    /// so the second pass finds nothing to change and only persists the result.
    @Published public var menuBarOrder: [ProviderKind] {
        didSet {
            let normalized = ProviderOrder.normalized(menuBarOrder)
            if normalized != menuBarOrder { menuBarOrder = normalized }
            defaults.set(menuBarOrder.map(\.rawValue), forKey: "menuBarOrder")
        }
    }
    @Published public var popoverOrder: [ProviderKind] {
        didSet {
            let normalized = ProviderOrder.normalized(popoverOrder)
            if normalized != popoverOrder { popoverOrder = normalized }
            defaults.set(popoverOrder.map(\.rawValue), forKey: "popoverOrder")
        }
    }
    // Optional popover details, applied to every provider section.
    @Published public var showDailyUsageInPopover: Bool {
        didSet { defaults.set(showDailyUsageInPopover, forKey: "popoverShowDailyUsage") }
    }
    @Published public var showResetTimeInPopover: Bool {
        didSet { defaults.set(showResetTimeInPopover, forKey: "popoverShowResetTime") }
    }
    @Published public var showLastUpdatedInPopover: Bool {
        didSet { defaults.set(showLastUpdatedInPopover, forKey: "popoverShowLastUpdated") }
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
    private var geminiFailures = 0
    /// Most recently scheduled poll intervals (observable by tests).
    private(set) var geminiRetryDelay: TimeInterval?
    private(set) var claudeRetryDelay: TimeInterval?
    private var trackerSubscriptions = Set<AnyCancellable>()
    /// App-server shutdown started by disabling Codex; a later read must wait for it.
    private var codexShutdown: Task<Void, Never>?
    private var claudeFailures = 0

    public init(client: AppServerConnection? = nil,
                geminiClient: GeminiUsageService? = nil,
                claudeClient: ClaudeUsageService? = nil,
                defaults: UserDefaults = .standard,
                weeklyTracker: WeeklyUsageTracker? = nil,
                geminiWeeklyTracker: WeeklyUsageTracker? = nil,
                claudeWeeklyTracker: WeeklyUsageTracker? = nil,
                legacySuiteName: String? = "dev.changjo.CodexUsage",
                locate: @escaping (String) throws -> URL = { try ExecutableLocator.resolve(customPath: $0) }) {
        // Settings from the pre-rename bundle are migrated once; tests pass nil to stay hermetic.
        let legacy = legacySuiteName.flatMap { UserDefaults(suiteName: $0) }
        let legacySuites = legacySuiteName.map { [$0] } ?? []
        let codexPath = defaults.string(forKey: "codexExecutablePath") ?? legacy?.string(forKey: "codexExecutablePath") ?? ""
        let agyPath = defaults.string(forKey: "agyExecutablePath") ?? legacy?.string(forKey: "agyExecutablePath") ?? ""
        let claudePath = defaults.string(forKey: "claudeExecutablePath") ?? legacy?.string(forKey: "claudeExecutablePath") ?? ""
        self.client = client ?? CodexAppServerClient()
        self.geminiClient = geminiClient ?? GeminiAgyClient(customPath: agyPath)
        self.claudeClient = claudeClient ?? ClaudeClient(customPath: claudePath)
        self.defaults = defaults
        self.weeklyTracker = weeklyTracker ?? WeeklyUsageTracker(userDefaults: defaults, legacySuiteNames: legacySuites)
        self.geminiWeeklyTracker = geminiWeeklyTracker ?? WeeklyUsageTracker(userDefaults: defaults, storageKey: "gemini_usage_weekly_tracker", legacySuiteNames: legacySuites)
        self.claudeWeeklyTracker = claudeWeeklyTracker ?? WeeklyUsageTracker(userDefaults: defaults, storageKey: "claude_usage_weekly_tracker", legacySuiteNames: legacySuites)
        self.locate = locate
        self.customPath = codexPath
        self.agyCustomPath = agyPath
        self.claudeCustomPath = claudePath

        self.showCodexInMenuBar = defaults.object(forKey: "menuBarShowCodex") as? Bool ?? legacy?.object(forKey: "menuBarShowCodex") as? Bool ?? true
        self.showGeminiInMenuBar = defaults.object(forKey: "menuBarShowGemini") as? Bool ?? legacy?.object(forKey: "menuBarShowGemini") as? Bool ?? true
        self.showClaudeInMenuBar = defaults.object(forKey: "menuBarShowClaude") as? Bool ?? legacy?.object(forKey: "menuBarShowClaude") as? Bool ?? true
        self.codexLabel = defaults.string(forKey: "serviceLabelCodex") ?? legacy?.string(forKey: "serviceLabelCodex") ?? "Codex"
        self.geminiLabel = defaults.string(forKey: "serviceLabelGemini") ?? legacy?.string(forKey: "serviceLabelGemini") ?? "Antigravity"
        self.claudeLabel = defaults.string(forKey: "serviceLabelClaude") ?? legacy?.string(forKey: "serviceLabelClaude") ?? "Claude"
        let modeRaw = defaults.string(forKey: "menuBarDisplayMode") ?? legacy?.string(forKey: "menuBarDisplayMode") ?? MenuBarDisplayMode.both.rawValue
        self.menuBarDisplayMode = MenuBarDisplayMode(rawValue: modeRaw) ?? .both
        self.menuBarOrder = ProviderOrder.normalized(rawValues: (defaults.array(forKey: "menuBarOrder") ?? []).compactMap { $0 as? String })
        self.popoverOrder = ProviderOrder.normalized(rawValues: (defaults.array(forKey: "popoverOrder") ?? []).compactMap { $0 as? String })
        self.showCodexInPopover = defaults.object(forKey: "popoverShowCodex") as? Bool ?? true
        self.showGeminiInPopover = defaults.object(forKey: "popoverShowGemini") as? Bool ?? true
        self.showClaudeInPopover = defaults.object(forKey: "popoverShowClaude") as? Bool ?? true
        self.showDailyUsageInPopover = defaults.object(forKey: "popoverShowDailyUsage") as? Bool ?? true
        self.showResetTimeInPopover = defaults.object(forKey: "popoverShowResetTime") as? Bool ?? true
        self.showLastUpdatedInPopover = defaults.object(forKey: "popoverShowLastUpdated") as? Bool ?? true
        self.isCodexEnabled = defaults.object(forKey: "providerEnabledCodex") as? Bool ?? true
        self.isGeminiEnabled = defaults.object(forKey: "providerEnabledGemini") as? Bool ?? true
        self.isClaudeEnabled = defaults.object(forKey: "providerEnabledClaude") as? Bool ?? true

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

        // Views read the trackers through the store, so their changes must republish the store.
        for tracker in [self.weeklyTracker, self.geminiWeeklyTracker, self.claudeWeeklyTracker] {
            tracker.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &trackerSubscriptions)
        }

        self.client.onNotification = { [weak self] event in self?.notified(event) }
        self.client.onDisconnect = { [weak self] error in
            guard let self, self.running, self.isCodexEnabled else { return }
            self.disconnectRevision += 1
            self.error = error
            if !self.isRefreshing { self.schedule(after: 60) }
        }
    }

    /// Labels shown in the UI; an empty custom label falls back to the provider name.
    public var codexName: String { Self.displayName(codexLabel, default: "Codex") }
    public var geminiName: String { Self.displayName(geminiLabel, default: "Antigravity") }
    public var claudeName: String { Self.displayName(claudeLabel, default: "Claude") }

    private static func displayName(_ label: String, default name: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    public func name(for kind: ProviderKind) -> String {
        switch kind {
        case .codex: return codexName
        case .gemini: return geminiName
        case .claude: return claudeName
        }
    }

    public func isEnabled(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .codex: return isCodexEnabled
        case .gemini: return isGeminiEnabled
        case .claude: return isClaudeEnabled
        }
    }

    public func isShownInMenuBar(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .codex: return showCodexInMenuBar
        case .gemini: return showGeminiInMenuBar
        case .claude: return showClaudeInMenuBar
        }
    }

    /// Menu bar text for one provider. A failed read shows "?" even when an older value exists:
    /// the menu bar cannot mark a value as stale, so it must not present it as current.
    private static func summary(_ value: String?, refreshing: Bool, failed: Bool) -> String {
        if failed { return "?" }
        return value ?? (refreshing ? "…" : "?")
    }

    public func isShownInPopover(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .codex: return showCodexInPopover
        case .gemini: return showGeminiInPopover
        case .claude: return showClaudeInPopover
        }
    }

    /// Popover sections: enabled providers shown in the popover, in popover order.
    public var popoverProviders: [ProviderKind] {
        popoverOrder.filter { isEnabled($0) && isShownInPopover($0) }
    }

    /// Some provider is enabled, but every enabled one is hidden from the popover. Unlike the menu
    /// bar, the popover does not fall back to showing one; it explains the empty state instead.
    public var allEnabledProvidersHiddenFromPopover: Bool {
        ProviderKind.allCases.contains { isEnabled($0) } && popoverProviders.isEmpty
    }

    /// Settings order-list tag: "Off" for a disabled provider, else "Hidden" when not in the menu bar.
    public func menuBarOrderTag(for kind: ProviderKind) -> String? {
        !isEnabled(kind) ? "Off" : (isShownInMenuBar(kind) ? nil : "Hidden")
    }

    /// Settings order-list tag: "Off" for a disabled provider, else "Hidden" when not in the popover.
    public func popoverOrderTag(for kind: ProviderKind) -> String? {
        !isEnabled(kind) ? "Off" : (isShownInPopover(kind) ? nil : "Hidden")
    }

    public var menuBarItems: [ProviderUsageItem] {
        let enabled = menuBarOrder.filter(isEnabled)
        let shown = enabled.filter(isShownInMenuBar)
        // Never leave the menu bar empty while a provider is enabled: show the first one.
        return (shown.isEmpty ? Array(enabled.prefix(1)) : shown).map(menuBarItem)
    }

    private func menuBarItem(for kind: ProviderKind) -> ProviderUsageItem {
        let mode = menuBarDisplayMode
        let value: String?
        let refreshing: Bool
        let failed: Bool
        switch kind {
        case .codex:
            (value, refreshing, failed) = (snapshot?.formattedValue(for: mode), isRefreshing, error != nil)
        case .gemini:
            (value, refreshing, failed) = (geminiSnapshot?.formattedValue(for: mode), isGeminiRefreshing, geminiError != nil)
        case .claude:
            (value, refreshing, failed) = (claudeSnapshot?.formattedValue(for: mode), isClaudeRefreshing, claudeError != nil)
        }
        return ProviderUsageItem(id: kind.rawValue, label: name(for: kind),
                                 summaryValue: Self.summary(value, refreshing: refreshing, failed: failed),
                                 isRefreshing: refreshing, hasError: failed)
    }

    /// Retry interval after `failures` consecutive failures: 60s doubling up to 5 minutes.
    func retryDelay(failures: Int) -> TimeInterval {
        min(300, 60 * pow(2, Double(max(0, failures - 1))))
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
        guard running, isCodexEnabled, refreshTask == nil else { return }
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
                await codexShutdown?.value
                guard epoch == current, !Task.isCancelled else { return }
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
            let delay = error != nil ? retryDelay(failures: failures) : (needsRefresh ? 0.5 : 60)
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
        let providerReads = [geminiRefreshTask, claudeRefreshTask].compactMap { $0 }
        geminiRefreshTask?.cancel()
        geminiRefreshTask = nil
        claudeRefreshTask?.cancel()
        claudeRefreshTask = nil
        isRefreshing = false
        isGeminiRefreshing = false
        isClaudeRefreshing = false
        snapshot = nil
        lastUpdated = nil
        geminiSnapshot = nil
        geminiLastUpdated = nil
        claudeSnapshot = nil
        claudeLastUpdated = nil
        needsRefresh = false
        if let cleanup {
            await cleanup.value
        } else {
            let operation = Task {
                await client.stop()
                await previous?.value
            }
            cleanup = operation
            await operation.value
            cleanup = nil
        }
        // A cancelled CLI read returns once its child has exited (SIGKILL after a short grace), so
        // waiting here guarantees no agy/claude process outlives quit or sleep.
        for read in providerReads { await read.value }
    }

    public func refreshGemini() {
        guard running, isGeminiEnabled, geminiRefreshTask == nil else { return }
        updateResolvedPath(.gemini)
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
                self.geminiFailures = 0
            } catch {
                guard !Task.isCancelled else { return }
                self.geminiError = (error as? UsageError) ?? .requestFailed
                self.geminiFailures = min(self.geminiFailures + 1, 4)
            }
            self.isGeminiRefreshing = false
            self.geminiRefreshTask = nil
            self.scheduleGemini(after: self.geminiError == nil ? 60 : self.retryDelay(failures: self.geminiFailures))
        }
    }

    private func scheduleGemini(after seconds: TimeInterval) {
        guard running, isGeminiEnabled else { return }
        geminiRetryDelay = seconds
        geminiScheduled?.cancel()
        geminiScheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            self?.refreshGemini()
        }
    }

    /// Validates and saves the agy path. An invalid explicit path is rejected and the previous
    /// setting is kept, matching the Codex behavior.
    public func applyAgyCustomPath(_ path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        geminiConfigurationError = nil
        // Return in the field can also trigger the default Apply button; apply only once.
        guard trimmed != agyCustomPath else { return }
        if !trimmed.isEmpty {
            do { _ = try ExecutableLocator.resolve(.gemini, customPath: trimmed) }
            catch {
                geminiConfigurationError = (error as? UsageError) ?? .cliNotFound
                return
            }
        }
        agyCustomPath = trimmed
        defaults.set(trimmed, forKey: "agyExecutablePath")
        if let agyClient = geminiClient as? GeminiAgyClient {
            agyClient.customPath = trimmed
        }
        updateResolvedPath(.gemini)
        restart(.gemini)
    }

    public func refreshClaude() {
        guard running, isClaudeEnabled, claudeRefreshTask == nil else { return }
        updateResolvedPath(.claude)
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
                self.claudeFailures = 0
            } catch {
                guard !Task.isCancelled else { return }
                self.claudeError = (error as? UsageError) ?? .requestFailed
                self.claudeFailures = min(self.claudeFailures + 1, 4)
            }
            self.isClaudeRefreshing = false
            self.claudeRefreshTask = nil
            self.scheduleClaude(after: self.claudeError == nil ? 60 : self.retryDelay(failures: self.claudeFailures))
        }
    }

    private func scheduleClaude(after seconds: TimeInterval) {
        guard running, isClaudeEnabled else { return }
        claudeRetryDelay = seconds
        claudeScheduled?.cancel()
        claudeScheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            self?.refreshClaude()
        }
    }

    public func applyClaudeCustomPath(_ path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeConfigurationError = nil
        guard trimmed != claudeCustomPath else { return }
        if !trimmed.isEmpty {
            do { _ = try ExecutableLocator.resolve(.claude, customPath: trimmed) }
            catch {
                claudeConfigurationError = (error as? UsageError) ?? .cliNotFound
                return
            }
        }
        claudeCustomPath = trimmed
        defaults.set(trimmed, forKey: "claudeExecutablePath")
        if let client = claudeClient as? ClaudeClient {
            client.customPath = trimmed
        }
        updateResolvedPath(.claude)
        restart(.claude)
    }

    /// Records which executable a provider will run, for Settings ("Using …").
    private func updateResolvedPath(_ kind: ProviderKind) {
        switch kind {
        case .gemini: geminiResolvedPath = (try? ExecutableLocator.resolve(.gemini, customPath: agyCustomPath))?.path
        case .claude: claudeResolvedPath = (try? ExecutableLocator.resolve(.claude, customPath: claudeCustomPath))?.path
        case .codex: break
        }
    }

    /// Gemini/Claude: drops any in-flight read (cancelling its child process) and polls again right
    /// away. Codex: only polls; its in-flight read is already invalidated by the disable path.
    private func restart(_ provider: ProviderKind) {
        switch provider {
        case .gemini:
            geminiRefreshTask?.cancel()
            geminiRefreshTask = nil
            isGeminiRefreshing = false
            geminiFailures = 0
            refreshGemini()
        case .claude:
            claudeRefreshTask?.cancel()
            claudeRefreshTask = nil
            isClaudeRefreshing = false
            claudeFailures = 0
            refreshClaude()
        case .codex:
            refreshCodex()
        }
    }

    private func providerEnablementChanged(_ provider: ProviderKind, from old: Bool, to enabled: Bool) {
        guard old != enabled else { return }
        switch provider {
        case .codex:
            defaults.set(enabled, forKey: "providerEnabledCodex")
            if !enabled {
                // Invalidate any in-flight read, then shut the app-server child down.
                epoch = UUID()
                scheduled?.cancel()
                scheduled = nil
                refreshTask?.cancel()
                refreshTask = nil
                isRefreshing = false
                snapshot = nil
                lastUpdated = nil
                error = nil
                needsRefresh = false
                failures = 0
                let client = self.client
                let previous = codexShutdown
                codexShutdown = Task {
                    await previous?.value
                    await client.stop()
                }
            }
        case .gemini:
            defaults.set(enabled, forKey: "providerEnabledGemini")
            if !enabled {
                geminiScheduled?.cancel()
                geminiScheduled = nil
                geminiRefreshTask?.cancel()
                geminiRefreshTask = nil
                isGeminiRefreshing = false
                geminiSnapshot = nil
                geminiLastUpdated = nil
                geminiError = nil
                geminiFailures = 0
            }
        case .claude:
            defaults.set(enabled, forKey: "providerEnabledClaude")
            if !enabled {
                claudeScheduled?.cancel()
                claudeScheduled = nil
                claudeRefreshTask?.cancel()
                claudeRefreshTask = nil
                isClaudeRefreshing = false
                claudeSnapshot = nil
                claudeLastUpdated = nil
                claudeError = nil
                claudeFailures = 0
            }
        }
        if enabled { restart(provider) }
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
        guard running, isCodexEnabled else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            // Codex has its own cadence; Gemini and Claude keep their own timers.
            self?.refreshCodex()
        }
    }
}
