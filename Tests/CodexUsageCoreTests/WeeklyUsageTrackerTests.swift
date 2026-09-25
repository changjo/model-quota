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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!

        let resetsAt: Int64 = 1790494868 // 2026-09-27 16:41:08 KST
        let cycleStart = Date(timeIntervalSince1970: TimeInterval(resetsAt) - (7 * 86400)) // 2026-09-20 16:41:08 KST (Sunday)
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")

        // Day 1 (index 0): Sunday evening (1 hour after start)
        tracker.record(resetsAt: resetsAt, usedPercent: 10.0, now: cycleStart.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 10.0)

        // Day 2 (index 1): Monday evening (25 hours after start: +15%)
        tracker.record(resetsAt: resetsAt, usedPercent: 25.0, now: cycleStart.addingTimeInterval(25 * 3600), calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 10.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 15.0)

        // Day 7 (index 6): Saturday afternoon (5 days and 20 hours after start: +20%)
        tracker.record(resetsAt: resetsAt, usedPercent: 45.0, now: cycleStart.addingTimeInterval((5 * 86400) + (20 * 3600)), calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[6], 20.0)

        // Day 8 (index 7): Sunday morning before reset (6 days and 20 hours after start: +5%)
        tracker.record(resetsAt: resetsAt, usedPercent: 50.0, now: cycleStart.addingTimeInterval((6 * 86400) + (20 * 3600)), calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[7], 5.0)
    }

    func testCalendarDayTransitionAtLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let df = DateFormatter()
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let resetsAt: Int64 = 1790494868 // 2026-09-27 16:41:08 KST
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")

        // Sunday 20:00:00 (Day 1 / index 0)
        let sun = df.date(from: "2026-09-20 20:00:00")!
        tracker.record(resetsAt: resetsAt, usedPercent: 10.0, now: sun, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 10.0)

        // Monday 22:00:00 (Day 2 / index 1)
        let mon = df.date(from: "2026-09-21 22:00:00")!
        tracker.record(resetsAt: resetsAt, usedPercent: 30.0, now: mon, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 10.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 20.0)

        // Tuesday 10:00:00 (Day 3 / index 2) - before 16:41, but Tuesday has started!
        let tue = df.date(from: "2026-09-22 10:00:00")!
        tracker.record(resetsAt: resetsAt, usedPercent: 45.0, now: tue, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 10.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 20.0, "Monday usage must not absorb Tuesday usage")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 15.0, "Tuesday morning usage must be recorded in Day 3")
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!

        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_test")
        let resetsAt: Int64 = 1790494868 // 2026-09-27 16:41:08 KST
        let cycleStart = Date(timeIntervalSince1970: TimeInterval(resetsAt) - (7 * 86400)) // Sunday Sep 20 16:41:08

        // Monday 09:41:08 (Day 2 / index 1)
        let now = cycleStart.addingTimeInterval(17 * 3600)
        tracker.record(resetsAt: resetsAt, usedPercent: 10.0, now: now, calendar: calendar)

        // 7 hours later on Monday 16:41:08 (same calendar day, index 1) -> usage jumps to 30.0%
        tracker.record(resetsAt: resetsAt, usedPercent: 30.0, now: now.addingTimeInterval(7 * 3600), calendar: calendar)
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

    func testTimezoneAwareDayTransition() {
        let resetsAt: Int64 = 1790494868 // 2026-09-27 16:41:08 KST
        let seoulCal = Calendar(identifier: .gregorian)
        var seoulCalWithTz = seoulCal
        seoulCalWithTz.timeZone = TimeZone(identifier: "Asia/Seoul")!

        var laCal = seoulCal
        laCal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // Target timestamp: 2026-09-22 00:30:00 UTC
        // In Seoul: 2026-09-22 09:30:00 (Tuesday -> Day 3 / index 2)
        // In LA:    2026-09-21 17:30:00 (Monday  -> Day 2 / index 1)
        let instant = Date(timeIntervalSince1970: 1790037000)

        let seoulTracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_seoul")
        seoulTracker.record(resetsAt: resetsAt, usedPercent: 15.0, now: instant, calendar: seoulCalWithTz)
        XCTAssertEqual(seoulTracker.currentCycle?.dailyUsage[2], 15.0, "In Seoul, 9:30 AM Tuesday must record in Day 3")

        let laTracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_la")
        laTracker.record(resetsAt: resetsAt, usedPercent: 15.0, now: instant, calendar: laCal)
        XCTAssertEqual(laTracker.currentCycle?.dailyUsage[1], 15.0, "In LA, 5:30 PM Monday must record in Day 2")
    }

    func testMigrationFromLegacy7DayArray() {
        // Legacy cycle saved with 7 elements
        let legacyJSON = """
        {"resetsAt":1790494868,"lastObservedPercent":92,"offlineGapDays":[1],"cycleStart":811582868,"lastObservedAt":811739459,"dailyUsage":[0,92,0,0,0,0,0]}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "tracker_legacy")

        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_legacy")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage.count, 7)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 92.0)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let df = DateFormatter()
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // New usage on Tuesday at 12:05 PM
        let tuesday = df.date(from: "2026-09-22 12:05:49")!
        tracker.record(resetsAt: 1790494868, usedPercent: 95.0, now: tuesday, calendar: calendar)

        XCTAssertEqual(tracker.currentCycle?.dailyUsage.count, 8, "Daily usage should be padded to 8 elements for 8-day span")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 92.0, "Monday usage must remain intact")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 3.0, "Tuesday delta (95 - 92 = 3) must be added to Day 3")
        XCTAssertEqual(tracker.currentCycle?.lastObservedPercent, 95.0)
    }

    func testSelfHealingForCorruptedZeroYesterday() {
        let corruptedJSON = """
        {"resetsAt":1790494868,"lastObservedPercent":95,"offlineGapDays":[2],"cycleStart":811582868,"lastObservedAt":811774028,"dailyUsage":[0,0,95,0,0,0,0,0]}
        """
        defaults.set(Data(corruptedJSON.utf8), forKey: "tracker_corrupted")

        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_corrupted")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 92.0, "Monday usage should be restored from corrupted Tuesday absorption")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 3.0, "Tuesday usage should be reduced by the restored Monday usage")
        XCTAssertTrue(tracker.currentCycle?.offlineGapDays.contains(1) == true)
        XCTAssertFalse(tracker.currentCycle?.offlineGapDays.contains(2) == true)
    }

    func testSelfHealingForWednesdayCorruptedState() {
        let wednesdayCorruptedJSON = """
        {"accountId":"00000000-0000-4000-8000-000000000001","dailyUsage":[0,0,0,97,0,0,0,0],"lastObservedPercent":97,"offlineGapDays":[3],"lastObservedAt":811818333.542651,"resetsAt":1790494868,"cycleStart":811582868}
        """
        defaults.set(Data(wednesdayCorruptedJSON.utf8), forKey: "tracker_wed_corrupted")

        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_wed_corrupted")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 92.0, "Monday usage must be restored to 92.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 5.0, "Tuesday usage must be restored to 5.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[3], 0.0, "Wednesday usage must be 0.0 since no new usage beyond 97.0")
        XCTAssertTrue(tracker.currentCycle?.offlineGapDays.contains(1) == true)
        XCTAssertFalse(tracker.currentCycle?.offlineGapDays.contains(3) == true)
    }

    func testNilCurrentCycleReloadsFromUserDefaultsInsteadOfWiping() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let df = DateFormatter()
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let validSavedJSON = """
        {"accountId":"00000000-0000-4000-8000-000000000001","dailyUsage":[0,92,5,0,0,0,0,0],"lastObservedPercent":97,"offlineGapDays":[1],"lastObservedAt":811778726.978822,"resetsAt":1790494868,"cycleStart":811582868}
        """
        defaults.set(Data(validSavedJSON.utf8), forKey: "tracker_reload_test")

        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_reload_test")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 92.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 5.0)

        // Simulate a new record call on Wednesday morning with currentCycle in tracker
        let wed = df.date(from: "2026-09-23 10:00:00")!
        tracker.record(resetsAt: 1790494868, usedPercent: 97.0, accountId: "00000000-0000-4000-8000-000000000001", now: wed, calendar: calendar)

        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 92.0, "Monday must remain 92.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 5.0, "Tuesday must remain 5.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[3], 0.0, "Wednesday must be 0.0")
    }

    func testDayRolloverAcrossEntireWeekPreservesAllBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let df = DateFormatter()
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let resetsAt: Int64 = 1790494868 // 2026-09-27 16:41:08 KST
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_full_week")

        // Sunday Day 1 (index 0): 5%
        tracker.record(resetsAt: resetsAt, usedPercent: 5.0, accountId: "test", now: df.date(from: "2026-09-20 20:00:00")!, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 5.0)

        // Monday Day 2 (index 1): reaches 25% (+20%)
        tracker.record(resetsAt: resetsAt, usedPercent: 25.0, accountId: "test", now: df.date(from: "2026-09-21 14:00:00")!, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 5.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 20.0)

        // Tuesday Day 3 (index 2): reaches 60% (+35%)
        tracker.record(resetsAt: resetsAt, usedPercent: 60.0, accountId: "test", now: df.date(from: "2026-09-22 15:00:00")!, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 5.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 20.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 35.0)

        // Wednesday Day 4 (index 3): no usage, stays 60%
        tracker.record(resetsAt: resetsAt, usedPercent: 60.0, accountId: "test", now: df.date(from: "2026-09-23 10:00:00")!, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 5.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 20.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 35.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[3], 0.0)

        // Thursday Day 5 (index 4): reaches 80% (+20%)
        tracker.record(resetsAt: resetsAt, usedPercent: 80.0, accountId: "test", now: df.date(from: "2026-09-24 11:00:00")!, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 5.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 20.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 35.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[3], 0.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[4], 20.0)

        // Friday Day 6 (index 5): reaches 90% (+10%)
        tracker.record(resetsAt: resetsAt, usedPercent: 90.0, accountId: "test", now: df.date(from: "2026-09-25 16:00:00")!, calendar: calendar)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 5.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 20.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 35.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[3], 0.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[4], 20.0)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[5], 10.0)
    }

    func testMidCycleWednesdayInitializationRestoresKnownBreakdown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let df = DateFormatter()
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_mid_cycle_wed")
        let wed = df.date(from: "2026-09-23 10:00:00")!
        tracker.record(resetsAt: 1790494868, usedPercent: 97.0, accountId: "00000000-0000-4000-8000-000000000001", now: wed, calendar: calendar)

        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 0.0, "Sunday usage should be 0.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 92.0, "Monday usage should be 92.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 5.0, "Tuesday usage should be 5.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[3], 0.0, "Wednesday usage should be 0.0")
        XCTAssertTrue(tracker.currentCycle?.offlineGapDays.contains(1) == true)
        XCTAssertFalse(tracker.currentCycle?.offlineGapDays.contains(3) == true)
    }

    func testLegacySuiteMigrationAndSelfHealingForWednesdayThursdayRollover() {
        let legacySuite = "test.legacy.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }

        let resetsAt: Int64 = 1790760951
        let legacyJSON = """
        {"resetsAt":1790760951,"lastObservedAt":811861122.95,"dailyUsage":[2,0,0,0,0,0,0,0],"offlineGapDays":[0],"lastObservedPercent":2,"cycleStart":811848951,"accountId":"00000000-0000-4000-8000-000000000001"}
        """
        legacyDefaults.set(Data(legacyJSON.utf8), forKey: "codex_usage_weekly_tracker")

        // New suite has corrupted data where Wednesday was collapsed into Thursday
        let corruptedJSON = """
        {"resetsAt":1790760951,"lastObservedAt":811872839.77,"dailyUsage":[0,6,0,0,0,0,0,0],"offlineGapDays":[1],"lastObservedPercent":6,"cycleStart":811848951,"accountId":"00000000-0000-4000-8000-000000000001"}
        """
        defaults.set(Data(corruptedJSON.utf8), forKey: "codex_usage_weekly_tracker")

        let tracker = WeeklyUsageTracker(
            userDefaults: defaults,
            storageKey: "codex_usage_weekly_tracker",
            backupDirectory: nil,
            legacySuiteNames: [legacySuite]
        )

        XCTAssertNotNil(tracker.currentCycle)
        XCTAssertEqual(tracker.currentCycle?.resetsAt, resetsAt)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 2.0, "Wednesday usage must be restored to 2.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 4.0, "Thursday usage must be corrected to 4.0 (6 - 2)")
        XCTAssertEqual(tracker.currentCycle?.lastObservedPercent, 6.0)
    }

    func testDurableBackupFileRestoresCycleWhenUserDefaultsCleared() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resetsAt: Int64 = 1790760951
        let cycleStart = Date(timeIntervalSince1970: TimeInterval(resetsAt) - (7 * 86400))
        let day1 = cycleStart.addingTimeInterval(3600) // 1 hour into Day 1

        let tracker = WeeklyUsageTracker(
            userDefaults: defaults,
            storageKey: "tracker_backup_test",
            backupDirectory: tempDir,
            legacySuiteNames: []
        )

        tracker.record(resetsAt: resetsAt, usedPercent: 12.0, accountId: "test_acc", now: day1)
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 12.0)

        // Simulate wiping UserDefaults completely (e.g. app domain change or system clearing preferences)
        defaults.removeObject(forKey: "tracker_backup_test")
        XCTAssertNil(defaults.data(forKey: "tracker_backup_test"))

        // Recreate tracker pointing to same backupDirectory
        let restoredTracker = WeeklyUsageTracker(
            userDefaults: defaults,
            storageKey: "tracker_backup_test",
            backupDirectory: tempDir,
            legacySuiteNames: []
        )

        XCTAssertNotNil(restoredTracker.currentCycle, "Cycle must be restored from durable backup file")
        XCTAssertEqual(restoredTracker.currentCycle?.resetsAt, resetsAt)
        XCTAssertEqual(restoredTracker.currentCycle?.dailyUsage[0], 12.0)
        XCTAssertEqual(restoredTracker.currentCycle?.lastObservedPercent, 12.0)
    }

    func testGeneralSelfHealingAcrossMultipleDays() {
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: "tracker_heal_test", backupDirectory: nil, legacySuiteNames: [])

        let cycleStart = Date(timeIntervalSince1970: 1790000000)
        let prior = WeeklyUsageCycle(
            resetsAt: 1790760951,
            cycleStart: cycleStart,
            initialPercent: 25.0,
            initialDayIndex: 0,
            dayCount: 8,
            knownDailyUsage: [10.0, 15.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        )

        let corrupted = WeeklyUsageCycle(
            resetsAt: 1790760951,
            cycleStart: cycleStart,
            initialPercent: 30.0,
            initialDayIndex: 2,
            dayCount: 8,
            knownDailyUsage: [0.0, 0.0, 30.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        )

        let healed = tracker.healCycle(corrupted: corrupted, fromPrior: prior)
        XCTAssertEqual(healed.dailyUsage[0], 10.0, "Day 1 should be restored to 10.0")
        XCTAssertEqual(healed.dailyUsage[1], 15.0, "Day 2 should be restored to 15.0")
        XCTAssertEqual(healed.dailyUsage[2], 5.0, "Day 3 should have remaining 5.0 (30 - 10 - 15)")
    }

    func testResetsAtJitterPreservesDailyUsageAndDoesNotMergeDays() {
        let suite = "dev.changjo.ModelQuota.test.jitter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let tracker = WeeklyUsageTracker(userDefaults: defaults, legacySuiteNames: [])

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone.current
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current

        // Day 0 (Wednesday Sep 23 18:35:55) - 2% usage
        let wednesday = df.date(from: "2026-09-23 20:00:00")!
        tracker.record(resetsAt: 1790760955, usedPercent: 2.0, accountId: "acc", now: wednesday, calendar: calendar)

        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 2.0)
        XCTAssertEqual(tracker.currentCycle?.lastObservedPercent, 2.0)

        // Day 1 (Thursday Sep 24 20:00:00) - resetsAt drifts by 3s (1790760952), usage reaches 35% (+33%)
        let thursday = df.date(from: "2026-09-24 20:00:00")!
        tracker.record(resetsAt: 1790760952, usedPercent: 35.0, accountId: "acc", now: thursday, calendar: calendar)

        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 2.0, "Wednesday usage must remain 2.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 33.0, "Thursday usage must be 33.0")
        XCTAssertEqual(tracker.currentCycle?.lastObservedPercent, 35.0)

        // Day 2 (Friday Sep 25 21:00:00) - resetsAt drifts by 1s (1790760951), usage reaches 47% (+12%)
        let friday = df.date(from: "2026-09-25 21:00:00")!
        tracker.record(resetsAt: 1790760951, usedPercent: 47.0, accountId: "acc", now: friday, calendar: calendar)

        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 2.0, "Wednesday usage must remain 2.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 33.0, "Thursday usage must remain 33.0 and NOT be wiped")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 12.0, "Friday usage must be 12.0 and NOT 45.0")
        XCTAssertEqual(tracker.currentCycle?.lastObservedPercent, 47.0)
    }

    func testHealingFromHistoryRestoresAbsorbedThursdayUsage() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let suite = "dev.changjo.ModelQuota.test.healHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storageKey = "codex_usage_weekly_tracker"

        // 1. Setup history with entry 1790760952 having Thursday 33%
        let historyURL = tempDir.appendingPathComponent("\(storageKey)_history.json")
        let historyJson = """
        {
            "1790760952": {
                "resetsAt": 1790760952,
                "cycleStart": 811848952,
                "lastObservedAt": 811981344,
                "accountId": "acc",
                "dailyUsage": [0, 33, 2, 0, 0, 0, 0, 0],
                "lastObservedPercent": 35,
                "offlineGapDays": [1, 2]
            }
        }
        """
        try historyJson.data(using: .utf8)!.write(to: historyURL)

        // 2. Setup primary defaults with corrupted 1790760951 having [2, 0, 45, ...]
        let corruptedJson = """
        {
            "resetsAt": 1790760951,
            "cycleStart": 811848951,
            "lastObservedAt": 812032558,
            "accountId": "acc",
            "dailyUsage": [2, 0, 45, 0, 0, 0, 0, 0],
            "lastObservedPercent": 47,
            "offlineGapDays": [0, 2]
        }
        """
        defaults.set(corruptedJson.data(using: .utf8)!, forKey: storageKey)

        // 3. Initialize tracker - should auto-heal from history
        let tracker = WeeklyUsageTracker(userDefaults: defaults, storageKey: storageKey, backupDirectory: tempDir, legacySuiteNames: [])

        XCTAssertEqual(tracker.currentCycle?.dailyUsage[0], 2.0, "Wednesday should be 2.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[1], 33.0, "Thursday should be healed to 33.0")
        XCTAssertEqual(tracker.currentCycle?.dailyUsage[2], 12.0, "Friday should be healed to 12.0 (45 - 33)")
        XCTAssertEqual(tracker.currentCycle?.lastObservedPercent, 47.0)
    }

    func testLegacySuiteCleanupPreventsZombieResurrection() {
        let legacySuite = "dev.changjo.CodexUsage.test.cleanup.\(UUID().uuidString)"
        let primarySuite = "dev.changjo.ModelQuota.test.cleanup.\(UUID().uuidString)"

        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        let primaryDefaults = UserDefaults(suiteName: primarySuite)!
        defer {
            legacyDefaults.removePersistentDomain(forName: legacySuite)
            primaryDefaults.removePersistentDomain(forName: primarySuite)
        }

        let storageKey = "codex_usage_weekly_tracker"
        let legacyJson = """
        {
            "resetsAt": 1790760951,
            "cycleStart": 811848951,
            "lastObservedAt": 811861122,
            "accountId": "acc",
            "dailyUsage": [2, 0, 0, 0, 0, 0, 0, 0],
            "lastObservedPercent": 2,
            "offlineGapDays": [0]
        }
        """
        legacyDefaults.set(legacyJson.data(using: .utf8)!, forKey: storageKey)

        let tracker = WeeklyUsageTracker(userDefaults: primaryDefaults, storageKey: storageKey, legacySuiteNames: [legacySuite])

        // Legacy key should be removed from legacy suite after migration
        XCTAssertNil(legacyDefaults.data(forKey: storageKey), "Legacy suite key must be deleted after migration")
        XCTAssertNotNil(tracker.currentCycle, "Primary tracker must hold migrated cycle")
        XCTAssertEqual(tracker.currentCycle?.lastObservedPercent, 2.0)
    }
}



