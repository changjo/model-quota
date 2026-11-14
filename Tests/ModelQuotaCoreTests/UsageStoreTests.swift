import XCTest
@testable import ModelQuotaCore

@MainActor
final class UsageStoreTests: XCTestCase {
    final class Connection: AppServerConnection {
        var isConnected = false
        var onNotification: ((AccountNotification) -> Void)?
        var onDisconnect: ((UsageError) -> Void)?
        var reads = 0
        var delayNextStop = false
        var stopContinuation: CheckedContinuation<Void, Never>?
        var continuation: CheckedContinuation<UsageSnapshot, Error>?
        func start(executable: URL) async throws { isConnected = true }
        func readUsage() async throws -> UsageSnapshot {
            reads += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func complete(_ result: Result<UsageSnapshot, Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
        func stop() async {
            isConnected = false
            complete(.failure(UsageError.stopped))
            if delayNextStop {
                delayNextStop = false
                await withCheckedContinuation { stopContinuation = $0 }
            }
        }
    }

    func snapshot() throws -> UsageSnapshot {
        try JSONDecoder().decode(UsageSnapshot.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":97,"windowDurationMins":10080}}}"#.utf8))
    }
    func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true")
    }
    /// Counts reads so tests can prove which providers a refresh path touches, and never spawns a real CLI.
    final class CountingGemini: GeminiUsageService {
        var reads = 0
        var error: UsageError? = .cliNotFound
        func readUsage() async throws -> GeminiUsageSnapshot {
            reads += 1
            if let error { throw error }
            return GeminiUsageSnapshot(groups: [])
        }
    }
    final class CountingClaude: ClaudeUsageService {
        var reads = 0
        var error: UsageError? = .cliNotFound
        func readUsage() async throws -> ClaudeUsageSnapshot {
            reads += 1
            if let error { throw error }
            return ClaudeUsageSnapshot()
        }
    }

    /// A throwaway preferences suite that is deleted after the test.
    func makeDefaults() -> UserDefaults {
        let name = "test.model-quota.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func codexValue(_ store: UsageStore) -> String? {
        store.menuBarItems.first { $0.id == "codex" }?.summaryValue
    }

    func makeStore(_ connection: Connection,
                   gemini: GeminiUsageService? = nil,
                   claude: ClaudeUsageService? = nil) -> UsageStore {
        UsageStore(client: connection, geminiClient: gemini ?? CountingGemini(), claudeClient: claude ?? CountingClaude(),
                   defaults: makeDefaults(), legacySuiteName: nil,
                   locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
    }

    func testCodexNotificationRefreshDoesNotRespawnOtherProviders() async throws {
        let connection = Connection()
        let gemini = CountingGemini()
        let claude = CountingClaude()
        let store = makeStore(connection, gemini: gemini, claude: claude)
        store.start()
        await waitUntil { connection.reads == 1 && gemini.reads == 1 && claude.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }

        // A Codex rate-limit notification must refresh only Codex.
        connection.onNotification?(.rateLimitsChanged(limitId: "codex"))
        await waitUntil { connection.reads == 2 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        XCTAssertEqual(gemini.reads, 1)
        XCTAssertEqual(claude.reads, 1)

        await store.stop()
    }

    func testDuplicateRefreshDoesNotStartParallelReads() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        store.refresh()
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        XCTAssertEqual(connection.reads, 1)
        XCTAssertEqual(codexValue(store), "3%")
        XCTAssertNotNil(store.lastUpdated)
        await store.stop()
    }

    func testAccountChangeDiscardsAnAlreadyInFlightSnapshot() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.onNotification?(.accountChanged)
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.lastUpdated)
        XCTAssertEqual(codexValue(store), "?")
        await store.stop()
    }

    func testOtherBucketNotificationDoesNotRefreshCodex() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        connection.onNotification?(.rateLimitsChanged(limitId: "other"))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(connection.reads, 1)
        await store.stop()
    }

    func testFailedRefreshDoesNotPresentPreviousValueAsCurrent() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        store.refresh()
        await waitUntil { connection.reads == 2 }
        connection.complete(.failure(UsageError.requestFailed))
        await waitUntil { !store.isRefreshing }
        XCTAssertEqual(codexValue(store), "?")
        XCTAssertNotNil(store.snapshot, "Keep old data for the explicitly stale detail view")
        XCTAssertEqual(store.error, .requestFailed)
        await store.stop()
    }

    func testStopCancelsPendingReadAndPreventsLateDisplay() async {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        await store.stop()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(connection.isConnected)
        XCTAssertNil(store.snapshot)
    }

    func testDisconnectBetweenResponseAndPublicationRemainsVisible() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        connection.isConnected = false
        connection.onDisconnect?(.connectionClosed)
        await waitUntil { !store.isRefreshing }
        XCTAssertEqual(codexValue(store), "?")
        XCTAssertEqual(store.error, .connectionClosed)
        XCTAssertNil(store.lastUpdated)
        await store.stop()
    }

    func testShutdownWaitsForSettingsCleanupAndPreventsRestart() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        connection.delayNextStop = true
        let settings = Task { await store.applyCustomPath("/usr/bin/true") }
        await waitUntil { connection.stopContinuation != nil }
        var shutdownFinished = false
        let shutdown = Task { await store.stop(); shutdownFinished = true }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(shutdownFinished, "Shutdown must await cleanup already in progress")
        connection.stopContinuation?.resume()
        connection.stopContinuation = nil
        await settings.value
        await shutdown.value
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(connection.isConnected, "Settings must not restart after sleep or shutdown")
        XCTAssertEqual(connection.reads, 1)
        await store.stop()
    }

    func testInvalidCustomPathKeepsWorkingConnectionAndSavedPreference() async throws {
        let connection = Connection()
        let defaults = makeDefaults()
        defaults.set("/working/codex", forKey: "codexExecutablePath")
        let store = UsageStore(client: connection, geminiClient: CountingGemini(), claudeClient: CountingClaude(),
                               defaults: defaults, legacySuiteName: nil, locate: { path in
            guard path != "/missing/codex" else { throw UsageError.cliNotFound }
            return URL(fileURLWithPath: "/working/codex")
        })
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        await store.applyCustomPath("/missing/codex")
        XCTAssertEqual(store.configurationError, .cliNotFound)
        XCTAssertEqual(store.customPath, "/working/codex")
        XCTAssertEqual(defaults.string(forKey: "codexExecutablePath"), "/working/codex")
        XCTAssertEqual(codexValue(store), "3%")
        XCTAssertTrue(connection.isConnected)
        XCTAssertNotNil(store.snapshot)
        await store.stop()
    }

    func testCustomPathAndAutomaticDetectionPersistAndReconnect() async throws {
        let connection = Connection()
        let defaults = makeDefaults()
        let store = UsageStore(client: connection, geminiClient: CountingGemini(), claudeClient: CountingClaude(),
                               defaults: defaults, legacySuiteName: nil, locate: { path in
            URL(fileURLWithPath: path.isEmpty ? "/automatic/codex" : path)
        })
        await store.applyCustomPath("  /custom/codex\n")
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        XCTAssertEqual(store.resolvedPath, "/custom/codex")
        XCTAssertEqual(defaults.string(forKey: "codexExecutablePath"), "/custom/codex")
        await store.applyCustomPath("")
        await waitUntil { connection.reads == 2 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        XCTAssertEqual(store.resolvedPath, "/automatic/codex")
        XCTAssertEqual(defaults.string(forKey: "codexExecutablePath"), "")
        XCTAssertEqual(codexValue(store), "3%")
        await store.stop()
    }

    func testWeeklyTrackerRecordsSnapshotAndClearsOnAccountChange() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }

        let snap = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: Data(#"{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1790494868}}}"#.utf8)
        )
        connection.complete(.success(snap))
        await waitUntil { !store.isRefreshing }

        XCTAssertNotNil(store.weeklyTracker.currentCycle)
        XCTAssertEqual(store.weeklyTracker.currentCycle?.resetsAt, 1790494868)
        XCTAssertEqual(store.weeklyTracker.currentCycle?.lastObservedPercent, 42.0)

        connection.onNotification?(.accountChanged)
        XCTAssertNil(store.weeklyTracker.currentCycle)

        await store.stop()
    }

    func testAccountUpdatedRefreshesWithoutClearingWeeklyTracker() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }

        let snap = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: Data(#"{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1790494868}}}"#.utf8)
        )
        connection.complete(.success(snap))
        await waitUntil { !store.isRefreshing }

        XCTAssertNotNil(store.weeklyTracker.currentCycle)
        XCTAssertEqual(store.weeklyTracker.currentCycle?.resetsAt, 1790494868)
        XCTAssertEqual(store.weeklyTracker.currentCycle?.lastObservedPercent, 42.0)

        // accountUpdated notification must NOT clear weekly tracker or nil out snapshot
        connection.onNotification?(.accountUpdated)
        XCTAssertNotNil(store.weeklyTracker.currentCycle)
        XCTAssertNotNil(store.snapshot)

        await store.stop()
    }

    func testGeminiRefreshUpdatesSnapshotAndMenuBarItems() async throws {
        let connection = Connection()
        let fixtureURL = Bundle.module.url(forResource: "agy-usage-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Tests/ModelQuotaCoreTests/Fixtures/agy-usage-sample.json")
        let geminiData = try Data(contentsOf: fixtureURL)
        let mockGemini = MockGeminiAgyClient(mockData: geminiData)

        let defaults = makeDefaults()
        let store = UsageStore(client: connection, geminiClient: mockGemini, claudeClient: CountingClaude(), defaults: defaults, legacySuiteName: nil,
                               locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        store.showClaudeInMenuBar = false
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && !store.isGeminiRefreshing }

        XCTAssertNotNil(store.geminiSnapshot)
        XCTAssertEqual(store.geminiSnapshot?.primaryRemainingPercent, 86)
        XCTAssertNotNil(store.geminiWeeklyTracker.currentCycle)
        XCTAssertEqual(store.geminiWeeklyTracker.currentCycle?.lastObservedPercent, store.geminiSnapshot?.weeklyBucket?.usedPercent)
        XCTAssertEqual(store.menuBarItems.count, 2)
        XCTAssertEqual(store.menuBarItems[0].label, "Codex")
        XCTAssertEqual(store.menuBarItems[1].label, "Gemini")

        // Test custom label change
        store.codexLabel = "GPT"
        store.geminiLabel = "GEM"
        XCTAssertEqual(store.menuBarItems[0].label, "GPT")
        XCTAssertEqual(store.menuBarItems[1].label, "GEM")

        // Test visibility toggle
        store.showGeminiInMenuBar = false
        XCTAssertEqual(store.menuBarItems.count, 1)
        XCTAssertEqual(store.menuBarItems[0].label, "GPT")

        await store.stop()
    }

    func testBackgroundRefreshPreservesExistingPercentagesInsteadOfShowingEllipsis() async throws {
        let connection = Connection()
        let fixtureURL = Bundle.module.url(forResource: "agy-usage-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Tests/ModelQuotaCoreTests/Fixtures/agy-usage-sample.json")
        let geminiData = try Data(contentsOf: fixtureURL)
        let mockGemini = MockGeminiAgyClient(mockData: geminiData)

        let defaults = makeDefaults()
        let store = UsageStore(client: connection, geminiClient: mockGemini, claudeClient: CountingClaude(), defaults: defaults, legacySuiteName: nil,
                               locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && !store.isGeminiRefreshing }

        XCTAssertEqual(store.menuBarItems[0].summaryValue, "3%")
        XCTAssertEqual(store.menuBarItems[1].summaryValue, "91% / 86%")

        store.refreshCodex()
        XCTAssertTrue(store.isRefreshing)
        // Background refresh must preserve valid existing snapshot values, never flash "…"
        XCTAssertEqual(store.menuBarItems[0].summaryValue, "3%")

        await waitUntil { connection.reads == 2 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }

        await store.stop()
    }

    func testClaudeIntegrationAndMenuBarItems() async throws {
        let connection = Connection()
        let streamJson = """
        {"type":"control_response","response":{"subtype":"success","response":{"subscription_type":"Claude Pro","rate_limits_available":true,"rate_limits":{"five_hour":{"resets_at":"2026-10-15T11:00:00.000Z","utilization":30.0},"seven_day":{"resets_at":"2026-10-21T06:00:00.000Z","utilization":60.0},"seven_day_breakdown":{"rows":[{"display_name":"Claude 3.7 Sonnet","key":"claude-3-7-sonnet","percent":55.0}]}}}}}
        """
        let mockClaude = MockClaudeClient(mockData: Data(streamJson.utf8))
        let fixtureURL = Bundle.module.url(forResource: "agy-usage-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Tests/ModelQuotaCoreTests/Fixtures/agy-usage-sample.json")
        let geminiData = try Data(contentsOf: fixtureURL)
        let mockGemini = MockGeminiAgyClient(mockData: geminiData)

        let defaults = makeDefaults()
        let store = UsageStore(
            client: connection,
            geminiClient: mockGemini,
            claudeClient: mockClaude,
            defaults: defaults, legacySuiteName: nil,
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && !store.isGeminiRefreshing && !store.isClaudeRefreshing }

        XCTAssertNotNil(store.claudeSnapshot)
        XCTAssertEqual(store.claudeSnapshot?.primaryRemainingPercent, 40)
        XCTAssertNotNil(store.claudeWeeklyTracker.currentCycle)
        XCTAssertEqual(store.claudeWeeklyTracker.currentCycle?.lastObservedPercent, 60.0)

        // Menu bar has 3 items
        XCTAssertEqual(store.menuBarItems.count, 3)
        XCTAssertEqual(store.menuBarItems[0].label, "Codex")
        XCTAssertEqual(store.menuBarItems[1].label, "Gemini")
        XCTAssertEqual(store.menuBarItems[2].label, "Claude")
        XCTAssertEqual(store.menuBarItems[2].summaryValue, "70% / 40%")

        // Custom label
        store.claudeLabel = "Claude Code"
        XCTAssertEqual(store.menuBarItems[2].label, "Claude Code")

        // Visibility toggle
        store.showClaudeInMenuBar = false
        XCTAssertEqual(store.menuBarItems.count, 2)

        await store.stop()
    }

    func testMenuBarDisplayModes() async throws {
        let connection = Connection()
        let streamJson = """
        {"type":"control_response","response":{"subtype":"success","response":{"subscription_type":"Claude Pro","rate_limits_available":true,"rate_limits":{"five_hour":{"resets_at":"2026-10-15T11:00:00.000Z","utilization":30.0},"seven_day":{"resets_at":"2026-10-21T06:00:00.000Z","utilization":60.0}}}}}
        """
        let mockClaude = MockClaudeClient(mockData: Data(streamJson.utf8))
        let fixtureURL = Bundle.module.url(forResource: "agy-usage-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Tests/ModelQuotaCoreTests/Fixtures/agy-usage-sample.json")
        let geminiData = try Data(contentsOf: fixtureURL)
        let mockGemini = MockGeminiAgyClient(mockData: geminiData)

        let defaults = makeDefaults()
        let store = UsageStore(
            client: connection,
            geminiClient: mockGemini,
            claudeClient: mockClaude,
            defaults: defaults, legacySuiteName: nil,
            locate: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && !store.isGeminiRefreshing && !store.isClaudeRefreshing }

        // 1. Both (default)
        store.menuBarDisplayMode = .both
        XCTAssertEqual(store.menuBarItems[1].summaryValue, "91% / 86%")
        XCTAssertEqual(store.menuBarItems[2].summaryValue, "70% / 40%")

        // 2. Weekly only
        store.menuBarDisplayMode = .weeklyOnly
        XCTAssertEqual(store.menuBarItems[1].summaryValue, "86%")
        XCTAssertEqual(store.menuBarItems[2].summaryValue, "40%")

        // 3. Session only
        store.menuBarDisplayMode = .sessionOnly
        XCTAssertEqual(store.menuBarItems[1].summaryValue, "91%")
        XCTAssertEqual(store.menuBarItems[2].summaryValue, "70%")

        // 4. Most restrictive
        store.menuBarDisplayMode = .mostRestrictive
        XCTAssertEqual(store.menuBarItems[1].summaryValue, "86%")
        XCTAssertEqual(store.menuBarItems[2].summaryValue, "40%")

        await store.stop()
    }

    func testEmptyLabelFallsBackToProviderName() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.codexLabel = "   "
        store.geminiLabel = ""
        store.claudeLabel = " Work "
        XCTAssertEqual(store.codexName, "Codex")
        XCTAssertEqual(store.geminiName, "Gemini")
        XCTAssertEqual(store.claudeName, "Work")
        XCTAssertEqual(store.menuBarItems.map(\.label), ["Codex", "Gemini", "Work"])
    }

    func testDisabledProviderIsNotPolledAndIsHiddenFromMenuBar() async throws {
        let connection = Connection()
        let gemini = CountingGemini()
        let claude = CountingClaude()
        let defaults = makeDefaults()
        defaults.set(false, forKey: "providerEnabledClaude")
        let store = UsageStore(client: connection, geminiClient: gemini, claudeClient: claude, defaults: defaults, legacySuiteName: nil,
                               locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        XCTAssertFalse(store.isClaudeEnabled)
        store.start()
        await waitUntil { connection.reads == 1 && gemini.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && !store.isGeminiRefreshing }
        XCTAssertEqual(claude.reads, 0)
        XCTAssertEqual(store.menuBarItems.map(\.id), ["codex", "gemini"])

        // Disabling clears state and persists; enabling refreshes immediately.
        store.isGeminiEnabled = false
        XCTAssertNil(store.geminiError)
        XCTAssertEqual(defaults.object(forKey: "providerEnabledGemini") as? Bool, false)
        XCTAssertEqual(store.menuBarItems.map(\.id), ["codex"])
        store.refresh()
        XCTAssertFalse(store.isGeminiRefreshing, "A disabled provider must not start a read")
        XCTAssertEqual(gemini.reads, 1)

        store.isClaudeEnabled = true
        await waitUntil { claude.reads == 1 }
        await store.stop()
    }

    func testDisablingCodexStopsTheAppServer() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && connection.isConnected }
        store.isCodexEnabled = false
        await waitUntil { !connection.isConnected }
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.menuBarItems.contains { $0.id == "codex" })
        store.refresh()
        XCTAssertFalse(store.isRefreshing)
        await store.stop()
    }

    func testMenuBarFallsBackToFirstEnabledProviderWhenAllHidden() async throws {
        let store = makeStore(Connection())
        store.showCodexInMenuBar = false
        store.showGeminiInMenuBar = false
        store.showClaudeInMenuBar = false
        XCTAssertEqual(store.menuBarItems.map(\.id), ["codex"])
        store.isCodexEnabled = false
        XCTAssertEqual(store.menuBarItems.map(\.id), ["gemini"])
        store.isGeminiEnabled = false
        store.isClaudeEnabled = false
        XCTAssertTrue(store.menuBarItems.isEmpty)
    }

    func testMenuBarItemsFollowTheMenuBarOrderOnly() async throws {
        let store = makeStore(Connection())
        XCTAssertEqual(store.menuBarItems.map(\.id), ["codex", "gemini", "claude"])
        store.menuBarOrder = [.claude, .codex, .gemini]
        XCTAssertEqual(store.menuBarItems.map(\.id), ["claude", "codex", "gemini"])
        XCTAssertEqual(store.menuBarItems.map(\.label), ["Claude", "Codex", "Gemini"])
        store.popoverOrder = [.gemini, .claude, .codex]
        XCTAssertEqual(store.menuBarItems.map(\.id), ["claude", "codex", "gemini"], "The popover order must not affect the menu bar")
        store.showCodexInMenuBar = false
        store.isGeminiEnabled = false
        XCTAssertEqual(store.menuBarItems.map(\.id), ["claude"])
    }

    func testMenuBarFallbackPicksTheFirstEnabledProviderInMenuBarOrder() async throws {
        let store = makeStore(Connection())
        store.menuBarOrder = [.claude, .gemini, .codex]
        store.showCodexInMenuBar = false
        store.showGeminiInMenuBar = false
        store.showClaudeInMenuBar = false
        XCTAssertEqual(store.menuBarItems.map(\.id), ["claude"])
        store.isClaudeEnabled = false
        XCTAssertEqual(store.menuBarItems.map(\.id), ["gemini"])
        store.isGeminiEnabled = false
        XCTAssertEqual(store.menuBarItems.map(\.id), ["codex"])
    }

    func testProviderOrdersAndPopoverElementsDefaultAndPersist() async throws {
        let defaults = makeDefaults()
        func makeStore() -> UsageStore {
            UsageStore(client: Connection(), geminiClient: CountingGemini(), claudeClient: CountingClaude(),
                       defaults: defaults, legacySuiteName: nil,
                       locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        }
        let store = makeStore()
        XCTAssertEqual(store.menuBarOrder, [.codex, .gemini, .claude])
        XCTAssertEqual(store.popoverOrder, [.codex, .gemini, .claude])
        XCTAssertTrue(store.showDailyUsageInPopover)
        XCTAssertTrue(store.showResetTimeInPopover)
        XCTAssertTrue(store.showLastUpdatedInPopover)

        store.menuBarOrder = [.gemini, .claude, .codex]
        store.popoverOrder = [.claude, .codex, .gemini]
        store.showDailyUsageInPopover = false
        store.showResetTimeInPopover = false
        store.showLastUpdatedInPopover = false
        XCTAssertEqual(defaults.stringArray(forKey: "menuBarOrder"), ["gemini", "claude", "codex"])
        XCTAssertEqual(defaults.stringArray(forKey: "popoverOrder"), ["claude", "codex", "gemini"])

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.menuBarOrder, [.gemini, .claude, .codex])
        XCTAssertEqual(reloaded.popoverOrder, [.claude, .codex, .gemini])
        XCTAssertFalse(reloaded.showDailyUsageInPopover)
        XCTAssertFalse(reloaded.showResetTimeInPopover)
        XCTAssertFalse(reloaded.showLastUpdatedInPopover)
        XCTAssertEqual(reloaded.menuBarItems.map(\.id), ["gemini", "claude", "codex"])

        reloaded.showResetTimeInPopover = true
        XCTAssertTrue(makeStore().showResetTimeInPopover)
    }

    func testStoredOrdersAreNormalizedOnLoad() async throws {
        let defaults = makeDefaults()
        defaults.set(["claude", "openai", "claude"], forKey: "menuBarOrder")
        defaults.set(["gemini", 7, "codex"] as [Any], forKey: "popoverOrder")
        let store = UsageStore(client: Connection(), geminiClient: CountingGemini(), claudeClient: CountingClaude(),
                               defaults: defaults, legacySuiteName: nil,
                               locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        XCTAssertEqual(store.menuBarOrder, [.claude, .codex, .gemini])
        XCTAssertEqual(store.popoverOrder, [.gemini, .codex, .claude])

        defaults.set("claude", forKey: "menuBarOrder")
        let fallback = UsageStore(client: Connection(), geminiClient: CountingGemini(), claudeClient: CountingClaude(),
                                  defaults: defaults, legacySuiteName: nil,
                                  locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        XCTAssertEqual(fallback.menuBarOrder, [.codex, .gemini, .claude], "A malformed value falls back to the default order")
    }

    func testSettingAnIncompleteOrderNormalizesAndPersistsIt() async throws {
        let defaults = makeDefaults()
        let store = UsageStore(client: Connection(), geminiClient: CountingGemini(), claudeClient: CountingClaude(),
                               defaults: defaults, legacySuiteName: nil,
                               locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        store.menuBarOrder = [.claude, .claude]
        XCTAssertEqual(store.menuBarOrder, [.claude, .codex, .gemini])
        XCTAssertEqual(defaults.stringArray(forKey: "menuBarOrder"), ["claude", "codex", "gemini"])
        store.popoverOrder = []
        XCTAssertEqual(store.popoverOrder, [.codex, .gemini, .claude])
        XCTAssertEqual(defaults.stringArray(forKey: "popoverOrder"), ["codex", "gemini", "claude"])
    }

    func testShowInPopoverDefaultsOnAndPersists() async throws {
        let defaults = makeDefaults()
        func makeStore() -> UsageStore {
            UsageStore(client: Connection(), geminiClient: CountingGemini(), claudeClient: CountingClaude(),
                       defaults: defaults, legacySuiteName: nil,
                       locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        }
        let store = makeStore()
        XCTAssertTrue(store.showCodexInPopover)
        XCTAssertTrue(store.showGeminiInPopover)
        XCTAssertTrue(store.showClaudeInPopover)

        store.showCodexInPopover = false
        store.showClaudeInPopover = false
        XCTAssertEqual(defaults.object(forKey: "popoverShowCodex") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "popoverShowGemini"))
        XCTAssertEqual(defaults.object(forKey: "popoverShowClaude") as? Bool, false)

        let reloaded = makeStore()
        XCTAssertFalse(reloaded.showCodexInPopover)
        XCTAssertTrue(reloaded.showGeminiInPopover)
        XCTAssertFalse(reloaded.showClaudeInPopover)
        XCTAssertEqual(ProviderKind.allCases.map(reloaded.isShownInPopover), [false, true, false])

        reloaded.showCodexInPopover = true
        XCTAssertTrue(makeStore().showCodexInPopover)
    }

    func testPopoverProvidersAreEnabledAndShownInPopoverOrder() async throws {
        let store = makeStore(Connection())
        XCTAssertEqual(store.popoverProviders, [.codex, .gemini, .claude])
        store.popoverOrder = [.claude, .codex, .gemini]
        XCTAssertEqual(store.popoverProviders, [.claude, .codex, .gemini])
        store.menuBarOrder = [.gemini, .claude, .codex]
        XCTAssertEqual(store.popoverProviders, [.claude, .codex, .gemini], "The menu bar order must not affect the popover")
        store.showCodexInPopover = false
        XCTAssertEqual(store.popoverProviders, [.claude, .gemini])
        store.isGeminiEnabled = false
        XCTAssertEqual(store.popoverProviders, [.claude])
        store.showClaudeInMenuBar = false
        XCTAssertEqual(store.popoverProviders, [.claude], "Menu bar visibility must not affect the popover")
    }

    func testProviderHiddenFromPopoverIsStillPolledAndShownInMenuBar() async throws {
        let connection = Connection()
        let gemini = CountingGemini()
        let claude = CountingClaude()
        let store = makeStore(connection, gemini: gemini, claude: claude)
        store.showCodexInPopover = false
        store.showGeminiInPopover = false
        store.showClaudeInPopover = false
        XCTAssertEqual(store.menuBarItems.map(\.id), ["codex", "gemini", "claude"])

        store.start()
        await waitUntil { connection.reads == 1 && gemini.reads == 1 && claude.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && !store.isGeminiRefreshing && !store.isClaudeRefreshing }
        XCTAssertEqual(codexValue(store), "3%")

        // A manual refresh still reads every enabled provider.
        store.refresh()
        await waitUntil { connection.reads == 2 && gemini.reads == 2 && claude.reads == 2 }
        await store.stop()
    }

    func testOrderTagsPreferOffOverHidden() async throws {
        let store = makeStore(Connection())
        XCTAssertEqual(ProviderKind.allCases.map(store.menuBarOrderTag(for:)), [nil, nil, nil])
        XCTAssertEqual(ProviderKind.allCases.map(store.popoverOrderTag(for:)), [nil, nil, nil])

        store.showGeminiInMenuBar = false
        store.showClaudeInPopover = false
        XCTAssertEqual(ProviderKind.allCases.map(store.menuBarOrderTag(for:)), [nil, "Hidden", nil])
        XCTAssertEqual(ProviderKind.allCases.map(store.popoverOrderTag(for:)), [nil, nil, "Hidden"])

        store.showCodexInMenuBar = false
        store.showCodexInPopover = false
        store.isCodexEnabled = false
        store.isClaudeEnabled = false
        XCTAssertEqual(ProviderKind.allCases.map(store.menuBarOrderTag(for:)), ["Off", "Hidden", "Off"])
        XCTAssertEqual(ProviderKind.allCases.map(store.popoverOrderTag(for:)), ["Off", nil, "Off"])
    }

    func testAllEnabledProvidersHiddenFromPopover() async throws {
        let store = makeStore(Connection())
        XCTAssertFalse(store.allEnabledProvidersHiddenFromPopover)
        store.showCodexInPopover = false
        store.showGeminiInPopover = false
        XCTAssertFalse(store.allEnabledProvidersHiddenFromPopover, "Claude is still shown")
        store.isClaudeEnabled = false
        XCTAssertTrue(store.allEnabledProvidersHiddenFromPopover, "Only hidden providers remain enabled")
        XCTAssertTrue(store.popoverProviders.isEmpty)
        store.isCodexEnabled = false
        store.isGeminiEnabled = false
        XCTAssertFalse(store.allEnabledProvidersHiddenFromPopover, "Nothing enabled is a different empty state")
        store.isGeminiEnabled = true
        XCTAssertTrue(store.allEnabledProvidersHiddenFromPopover)
        store.showGeminiInPopover = true
        XCTAssertFalse(store.allEnabledProvidersHiddenFromPopover)
        XCTAssertEqual(store.popoverProviders, [.gemini])
    }

    func testProviderLookupsMatchThePerProviderProperties() async throws {
        let store = makeStore(Connection())
        store.claudeLabel = "Work"
        store.isGeminiEnabled = false
        store.showClaudeInMenuBar = false
        XCTAssertEqual(ProviderKind.allCases.map(store.name(for:)), ["Codex", "Gemini", "Work"])
        XCTAssertEqual(ProviderKind.allCases.map(store.isEnabled), [true, false, true])
        XCTAssertEqual(ProviderKind.allCases.map(store.isShownInMenuBar), [true, true, false])
    }

    func testFailingProvidersBackOff() async throws {
        let store = makeStore(Connection())
        XCTAssertEqual(store.retryDelay(failures: 0), 60)
        XCTAssertEqual(store.retryDelay(failures: 1), 60)
        XCTAssertEqual(store.retryDelay(failures: 2), 120)
        XCTAssertEqual(store.retryDelay(failures: 3), 240)
        XCTAssertEqual(store.retryDelay(failures: 9), 300)
    }

    func testInvalidGeminiAndClaudePathsAreRejectedWithoutSaving() async throws {
        let connection = Connection()
        let defaults = makeDefaults()
        let store = UsageStore(client: connection, geminiClient: CountingGemini(), claudeClient: CountingClaude(),
                               defaults: defaults, legacySuiteName: nil, locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        await store.applyAgyCustomPath("/no/such/agy")
        XCTAssertEqual(store.geminiConfigurationError, .cliNotFound)
        XCTAssertEqual(store.agyCustomPath, "")
        XCTAssertNil(defaults.string(forKey: "agyExecutablePath"))

        await store.applyClaudeCustomPath("/no/such/claude")
        XCTAssertEqual(store.claudeConfigurationError, .cliNotFound)
        XCTAssertEqual(store.claudeCustomPath, "")

        await store.applyAgyCustomPath(" /usr/bin/true ")
        XCTAssertNil(store.geminiConfigurationError)
        XCTAssertEqual(store.agyCustomPath, "/usr/bin/true")
        XCTAssertEqual(defaults.string(forKey: "agyExecutablePath"), "/usr/bin/true")
    }

    func testApplyingPathRetriesImmediatelyEvenWhileARefreshIsInFlight() async throws {
        final class SlowGemini: GeminiUsageService {
            var reads = 0
            func readUsage() async throws -> GeminiUsageSnapshot {
                reads += 1
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw UsageError.timedOut
            }
        }
        let connection = Connection()
        let gemini = SlowGemini()
        let store = makeStore(connection, gemini: gemini)
        store.start()
        await waitUntil { gemini.reads == 1 }
        await store.applyAgyCustomPath("/usr/bin/true")
        await waitUntil { gemini.reads == 2 }
        await store.stop()
    }

    func testStopClearsEveryProviderSnapshot() async throws {
        let connection = Connection()
        let fixtureURL = Bundle.module.url(forResource: "agy-usage-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Tests/ModelQuotaCoreTests/Fixtures/agy-usage-sample.json")
        let store = makeStore(connection, gemini: MockGeminiAgyClient(mockData: try Data(contentsOf: fixtureURL)))
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { store.geminiSnapshot != nil && !store.isRefreshing }
        await store.stop()
        XCTAssertNil(store.geminiSnapshot)
        XCTAssertNil(store.geminiLastUpdated)
    }

    func testFailureShowsUnknownInMenuBarInsteadOfStaleValue() async throws {
        let connection = Connection()
        let gemini = CountingGemini()
        gemini.error = nil
        let store = makeStore(connection, gemini: gemini)
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && !store.isGeminiRefreshing }
        XCTAssertEqual(store.menuBarItems.first { $0.id == "codex" }?.summaryValue, "3%")

        store.refreshCodex()
        await waitUntil { connection.reads == 2 }
        connection.complete(.failure(UsageError.timedOut))
        await waitUntil { !store.isRefreshing }
        let codex = try XCTUnwrap(store.menuBarItems.first { $0.id == "codex" })
        XCTAssertEqual(codex.summaryValue, "?")
        XCTAssertTrue(codex.hasError)
        XCTAssertNotNil(store.snapshot, "The popover still shows the last known values, marked stale")
        await store.stop()
    }

    func testTrackerChangesRepublishTheStore() async throws {
        let store = makeStore(Connection())
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        store.claudeWeeklyTracker.record(resetsAt: 1_795_165_200, usedPercent: 5, accountId: "claude")
        XCTAssertGreaterThan(changes, 0)
        subscription.cancel()
    }

    func testQuicklyReenablingCodexWaitsForTheShutdownBeforeReading() async throws {
        let connection = Connection()
        let store = makeStore(connection)
        store.start()
        await waitUntil { connection.reads == 1 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing && connection.isConnected }
        connection.delayNextStop = true
        store.isCodexEnabled = false
        store.isCodexEnabled = true
        // The shutdown is still in progress, so no read may go out on the dying connection yet.
        await waitUntil { connection.stopContinuation != nil }
        XCTAssertEqual(connection.reads, 1)
        connection.stopContinuation?.resume()
        connection.stopContinuation = nil
        await waitUntil { connection.reads == 2 }
        connection.complete(.success(try snapshot()))
        await waitUntil { !store.isRefreshing }
        XCTAssertNil(store.error)
        XCTAssertEqual(codexValue(store), "3%")
        await store.stop()
    }

    func testFailingGeminiAndClaudeActuallyScheduleWithBackoff() async throws {
        let gemini = CountingGemini()
        let claude = CountingClaude()
        let store = makeStore(Connection(), gemini: gemini, claude: claude)
        store.start()
        await waitUntil { gemini.reads == 1 && claude.reads == 1 && !store.isGeminiRefreshing && !store.isClaudeRefreshing }
        XCTAssertEqual(store.geminiRetryDelay, 60)
        XCTAssertEqual(store.claudeRetryDelay, 60)
        store.refreshGemini()
        store.refreshClaude()
        await waitUntil { gemini.reads == 2 && claude.reads == 2 && !store.isGeminiRefreshing && !store.isClaudeRefreshing }
        XCTAssertEqual(store.geminiRetryDelay, 120)
        XCTAssertEqual(store.claudeRetryDelay, 120)
        gemini.error = nil
        store.refreshGemini()
        await waitUntil { gemini.reads == 3 && !store.isGeminiRefreshing }
        XCTAssertEqual(store.geminiRetryDelay, 60)
        await store.stop()
    }

    func testResolvedPathsAreReportedForGeminiAndClaude() async throws {
        let store = makeStore(Connection())
        await store.applyAgyCustomPath("/usr/bin/true")
        await store.applyClaudeCustomPath("/bin/sh")
        XCTAssertEqual(store.geminiResolvedPath, "/usr/bin/true")
        XCTAssertEqual(store.claudeResolvedPath, "/bin/sh")
        await store.applyClaudeCustomPath("/no/such/claude")
        XCTAssertEqual(store.claudeResolvedPath, "/bin/sh", "A rejected path leaves the previous one in use")
    }

    func testStopWaitsForCancelledProviderReadsSoNoChildOutlivesTheApp() async throws {
        /// Models a CLI child that is still exiting after cancellation.
        final class SlowToExitGemini: GeminiUsageService {
            var reads = 0
            var finish: CheckedContinuation<Void, Never>?
            func readUsage() async throws -> GeminiUsageSnapshot {
                reads += 1
                await withCheckedContinuation { finish = $0 }
                throw CancellationError()
            }
        }
        let gemini = SlowToExitGemini()
        let connection = Connection()
        let store = makeStore(connection, gemini: gemini)
        store.start()
        await waitUntil { gemini.reads == 1 && connection.reads == 1 }
        var stopped = false
        let stopping = Task { await store.stop(); stopped = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(stopped, "stop() must wait until the provider's child has exited")
        gemini.finish?.resume()
        await stopping.value
        XCTAssertTrue(stopped)
    }
}
