import XCTest
@testable import CodexUsageCore

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
    func makeStore(_ connection: Connection) -> UsageStore {
        UsageStore(client: connection, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                   locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
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
        XCTAssertEqual(store.menuBarTitle, "Codex 3%")
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
        XCTAssertEqual(store.menuBarTitle, "Codex ?")
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
        XCTAssertEqual(store.menuBarTitle, "Codex ?")
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
        XCTAssertEqual(store.menuBarTitle, "Codex ?")
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
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("/working/codex", forKey: "codexExecutablePath")
        let store = UsageStore(client: connection, defaults: defaults, locate: { path in
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
        XCTAssertEqual(store.menuBarTitle, "Codex 3%")
        XCTAssertTrue(connection.isConnected)
        XCTAssertNotNil(store.snapshot)
        await store.stop()
    }

    func testCustomPathAndAutomaticDetectionPersistAndReconnect() async throws {
        let connection = Connection()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UsageStore(client: connection, defaults: defaults, locate: { path in
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
        XCTAssertEqual(store.menuBarTitle, "Codex 3%")
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
            ?? URL(fileURLWithPath: "Tests/CodexUsageCoreTests/Fixtures/agy-usage-sample.json")
        let geminiData = try Data(contentsOf: fixtureURL)
        let mockGemini = MockGeminiAgyClient(mockData: geminiData)

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UsageStore(client: connection, geminiClient: mockGemini, defaults: defaults,
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
            ?? URL(fileURLWithPath: "Tests/CodexUsageCoreTests/Fixtures/agy-usage-sample.json")
        let geminiData = try Data(contentsOf: fixtureURL)
        let mockGemini = MockGeminiAgyClient(mockData: geminiData)

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UsageStore(client: connection, geminiClient: mockGemini, defaults: defaults,
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
            ?? URL(fileURLWithPath: "Tests/CodexUsageCoreTests/Fixtures/agy-usage-sample.json")
        let geminiData = try Data(contentsOf: fixtureURL)
        let mockGemini = MockGeminiAgyClient(mockData: geminiData)

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UsageStore(
            client: connection,
            geminiClient: mockGemini,
            claudeClient: mockClaude,
            defaults: defaults,
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
            ?? URL(fileURLWithPath: "Tests/CodexUsageCoreTests/Fixtures/agy-usage-sample.json")
        let geminiData = try Data(contentsOf: fixtureURL)
        let mockGemini = MockGeminiAgyClient(mockData: geminiData)

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UsageStore(
            client: connection,
            geminiClient: mockGemini,
            claudeClient: mockClaude,
            defaults: defaults,
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
}
