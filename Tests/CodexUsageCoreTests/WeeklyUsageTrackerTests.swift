import XCTest
@testable import CodexUsageCore

@MainActor
final class WeeklyUsageTrackerTests: XCTestCase {
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.codex.usage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCycleDayIndexCalculation() {
        let resetsAt: Int64 = 1790494868 // 2026-09-27 16:41:08
        let cycleStart = Date(timeIntervalSince1970: TimeInterval(resetsAt) - (7 * 86400))
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")

        // Day 1 (index 0): 1 hour after start
        tracker.record(resetsAt: resetsAt, usedPercent: 10.0, now: cycleStart.addingTimeInterval(3600))
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 10.0)

        // Day 2 (index 1): 25 hours after start (+15%)
        tracker.record(resetsAt: resetsAt, usedPercent: 25.0, now: cycleStart.addingTimeInterval(25 * 3600))
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 10.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 15.0)

        // Day 7 (index 6): 6 days and 20 hours after start (+20%)
        tracker.record(resetsAt: resetsAt, usedPercent: 45.0, now: cycleStart.addingTimeInterval((6 * 86400) + (20 * 3600)))
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[6], 20.0)
    }

    func testWeeklyCycleResetStartsNewRecord() {
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")
        let resetsAt1: Int64 = 1790494868
        let now1 = Date(timeIntervalSince1970: TimeInterval(resetsAt1) - 86400)
        tracker.record(resetsAt: resetsAt1, usedPercent: 80.0, now: now1)
        XCTAssertEqual(tracker.currentCycle?.resetsAt, resetsAt1)

        let resetsAt2: Int64 = resetsAt1 + (7 * 86400)
        let now2 = Date(timeIntervalSince1970: TimeInterval(resetsAt1) + 3600)
        tracker.record(resetsAt: resetsAt2, usedPercent: 5.0, now: now2)
        XCTAssertEqual(tracker.currentCycle?.resetsAt, resetsAt2)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 5.0)
    }

    func testUsageDecreaseHandledSafely() {
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")
        let resetsAt: Int64 = 1790494868
        let now = Date(timeIntervalSince1970: TimeInterval(resetsAt) - 5 * 86400)
        tracker.record(resetsAt: resetsAt, usedPercent: 50.0, now: now)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 50.0)

        // Reset credit used, usage drops to 10.0%
        tracker.record(resetsAt: resetsAt, usedPercent: 10.0, now: now.addingTimeInterval(60))
        XCTAssertEqual(tracker.currentCycle?.lastObservedPercent, 10.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 50.0) // No negative subtraction
    }

    func testOfflineGapDetection() {
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")
        let resetsAt: Int64 = 1790494868
        let now = Date(timeIntervalSince1970: TimeInterval(resetsAt) - 6 * 86400)
        tracker.record(resetsAt: resetsAt, usedPercent: 10.0, now: now)

        // 8 hours later, usage jumps to 30.0%
        tracker.record(resetsAt: resetsAt, usedPercent: 30.0, now: now.addingTimeInterval(8 * 3600))
        XCTAssertTrue(tracker.currentCycle?.offlineGapDays.contains(1) == true)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 30.0)
    }

    func testClearRemovesCycle() {
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")
        tracker.record(resetsAt: 1790494868, usedPercent: 15.0, now: Date())
        XCTAssertNotNil(tracker.currentCycle)

        tracker.clear()
        XCTAssertNil(tracker.currentCycle)

        let reloaded = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")
        XCTAssertNil(reloaded.currentCycle)
    }
}
