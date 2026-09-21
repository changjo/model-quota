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

    private let client: AppServerConnection
    private let defaults: UserDefaults
    private let locate: (String) throws -> URL
    private var refreshTask: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var epoch = UUID()
    private var lifecycleRevision = 0
    private var disconnectRevision = 0
    private var accountRevision = 0
    private var needsRefresh = false
    private var failures = 0

    public init(client: AppServerConnection? = nil, defaults: UserDefaults = .standard,
                locate: @escaping (String) throws -> URL = { try ExecutableLocator.resolve(customPath: $0) }) {
        self.client = client ?? CodexAppServerClient()
        self.defaults = defaults
        self.locate = locate
        self.customPath = defaults.string(forKey: "codexExecutablePath") ?? ""
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

    public func start() {
        guard !running else { return }
        lifecycleRevision += 1
        running = true
        refresh()
    }

    public func refresh() {
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
        let previous = refreshTask
        refreshTask = nil
        previous?.cancel()
        isRefreshing = false
        snapshot = nil
        lastUpdated = nil
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
