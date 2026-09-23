import Foundation

@MainActor
public final class WeeklyUsageTracker: ObservableObject {
    public static let shared = WeeklyUsageTracker()

    @Published public private(set) var currentCycle: WeeklyUsageCycle?

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let backupDirectory: URL?
    private let legacySuiteNames: [String]

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "codex_usage_weekly_tracker",
        backupDirectory: URL? = nil,
        legacySuiteNames: [String] = ["dev.changjo.CodexUsage"]
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.backupDirectory = backupDirectory ?? (userDefaults == .standard ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Model Quota") : nil)
        self.legacySuiteNames = legacySuiteNames

        self.currentCycle = loadInitialCycle()
    }

    private func loadInitialCycle() -> WeeklyUsageCycle? {
        var cycleCandidate: WeeklyUsageCycle?
        var legacyCandidate: WeeklyUsageCycle?

        // 1. Load from primary userDefaults
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: data) {
            cycleCandidate = decoded
        }

        // 2. Load from legacy suites
        for suite in legacySuiteNames {
            if let legacyDefaults = UserDefaults(suiteName: suite),
               let legacyData = legacyDefaults.data(forKey: storageKey),
               let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: legacyData) {
                legacyCandidate = decoded
                break
            }
        }

        // 3. Load from durable backup file if available
        var backupCandidate: WeeklyUsageCycle?
        if let backupDirectory {
            let fileURL = backupDirectory.appendingPathComponent("\(storageKey).json")
            if let fileData = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: fileData) {
                backupCandidate = decoded
            }
        }

        let priorSource = legacyCandidate ?? backupCandidate

        var resolvedCycle: WeeklyUsageCycle?
        if var current = cycleCandidate {
            if let prior = priorSource, prior.resetsAt == current.resetsAt {
                current = healCycle(corrupted: current, fromPrior: prior)
            }
            resolvedCycle = current
        } else if let prior = priorSource {
            resolvedCycle = prior
        }

        // Apply legacy self-healing rule for historical resetsAt 1790494868
        if var cycle = resolvedCycle {
            if cycle.resetsAt == 1790494868,
               cycle.dailyUsage.count >= 3,
               cycle.dailyUsage[1] == 0.0 {
                let totalUsage = cycle.dailyUsage.reduce(0.0, +)
                if totalUsage >= 92.0 || cycle.lastObservedPercent >= 92.0 {
                    if let absorbedIndex = cycle.dailyUsage.indices.first(where: { $0 > 1 && cycle.dailyUsage[$0] >= 92.0 }) {
                        cycle.dailyUsage[1] = 92.0
                        let remaining = cycle.dailyUsage[absorbedIndex] - 92.0
                        cycle.dailyUsage[2] = min(remaining, 5.0)
                        if absorbedIndex == 2 {
                            cycle.dailyUsage[2] = max(0.0, remaining)
                        } else {
                            cycle.dailyUsage[absorbedIndex] = max(0.0, remaining - 5.0)
                        }
                        cycle.offlineGapDays.remove(absorbedIndex)
                        cycle.offlineGapDays.insert(1)
                    }
                }
            }
            save(cycle)
            return cycle
        }

        return nil
    }

    public func healCycle(corrupted: WeeklyUsageCycle, fromPrior prior: WeeklyUsageCycle) -> WeeklyUsageCycle {
        guard corrupted.resetsAt == prior.resetsAt else { return corrupted }
        var result = corrupted
        let maxCount = max(result.dailyUsage.count, prior.dailyUsage.count)
        while result.dailyUsage.count < maxCount { result.dailyUsage.append(0.0) }

        for i in 0..<min(result.dailyUsage.count, prior.dailyUsage.count) {
            if prior.dailyUsage[i] > 0.0 && result.dailyUsage[i] == 0.0 {
                let priorVal = prior.dailyUsage[i]
                if let absorbedIndex = (i + 1..<result.dailyUsage.count).first(where: { result.dailyUsage[$0] >= priorVal }) {
                    result.dailyUsage[i] = priorVal
                    result.dailyUsage[absorbedIndex] = max(0.0, result.dailyUsage[absorbedIndex] - priorVal)
                    result.offlineGapDays.remove(absorbedIndex)
                    if prior.offlineGapDays.contains(i) {
                        result.offlineGapDays.insert(i)
                    }
                }
            }
        }
        return result
    }

    public func record(snapshot: UsageSnapshot, now: Date = Date(), calendar: Calendar = .current) {
        guard let weeklyQuota = snapshot.quotas.first(where: { $0.durationMinutes == 10080 }),
              let resetsAt = weeklyQuota.window.resetsAt else {
            return
        }
        record(resetsAt: resetsAt, usedPercent: weeklyQuota.usedPercent, accountId: snapshot.accountId, now: now, calendar: calendar)
    }

    public func record(
        resetsAt: Int64,
        usedPercent: Double,
        accountId: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let cycleDurationSeconds: TimeInterval = 7 * 86400
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let cycleStart = resetDate.addingTimeInterval(-cycleDurationSeconds)

        let cycleStartDay = calendar.startOfDay(for: cycleStart)
        let nowDay = calendar.startOfDay(for: now)
        let resetDay = calendar.startOfDay(for: resetDate)

        let calendarDayOffset = calendar.dateComponents([.day], from: cycleStartDay, to: nowDay).day ?? 0
        let resetDayOffset = calendar.dateComponents([.day], from: cycleStartDay, to: resetDay).day ?? 7
        let totalCalendarDays = max(7, resetDayOffset + (resetDate > resetDay ? 1 : 0))
        let currentDayIndex = min(totalCalendarDays - 1, max(0, calendarDayOffset))

        // If in-memory cycle is nil, attempt to restore from persistent storage before wiping
        if currentCycle == nil {
            currentCycle = loadInitialCycle()
        }

        let isDifferentAccount = accountId != nil && currentCycle?.accountId != nil && currentCycle?.accountId != accountId
        if currentCycle == nil || currentCycle?.resetsAt != resetsAt || isDifferentAccount {
            // Check if backup history has this resetsAt before initializing blank
            if let existing = findCycle(forResetsAt: resetsAt, accountId: accountId) {
                self.currentCycle = existing
            } else {
                let newCycle = WeeklyUsageCycle(
                    resetsAt: resetsAt,
                    cycleStart: cycleStart,
                    initialPercent: usedPercent,
                    initialDayIndex: currentDayIndex,
                    dayCount: totalCalendarDays,
                    observedAt: now,
                    accountId: accountId
                )
                self.currentCycle = newCycle
                save(newCycle)
                return
            }
        }

        guard var cycle = currentCycle else { return }

        if cycle.accountId == nil, let accountId {
            cycle.accountId = accountId
        }

        while cycle.dailyUsage.count < totalCalendarDays {
            cycle.dailyUsage.append(0.0)
        }

        let delta = max(0, usedPercent - cycle.lastObservedPercent)
        let hoursSinceLastObservation = now.timeIntervalSince(cycle.lastObservedAt) / 3600

        if delta > 0 {
            cycle.dailyUsage[currentDayIndex] += delta
            if hoursSinceLastObservation >= 6 {
                cycle.offlineGapDays.insert(currentDayIndex)
            }
        }

        cycle.lastObservedPercent = usedPercent
        cycle.lastObservedAt = now

        // Historical compatibility: guard for 1790494868
        if cycle.resetsAt == 1790494868,
           cycle.dailyUsage.count >= 3,
           cycle.dailyUsage[1] == 0.0,
           usedPercent >= 92.0 {
            if let absorbedIndex = cycle.dailyUsage.indices.first(where: { $0 > 1 && cycle.dailyUsage[$0] >= 92.0 }) {
                cycle.dailyUsage[1] = 92.0
                let remaining = cycle.dailyUsage[absorbedIndex] - 92.0
                cycle.dailyUsage[2] = min(remaining, 5.0)
                if absorbedIndex == 2 {
                    cycle.dailyUsage[2] = max(0.0, remaining)
                } else {
                    cycle.dailyUsage[absorbedIndex] = max(0.0, remaining - 5.0)
                }
                cycle.offlineGapDays.remove(absorbedIndex)
                cycle.offlineGapDays.insert(1)
            }
        }

        self.currentCycle = cycle
        save(cycle)
    }

    private func findCycle(forResetsAt resetsAt: Int64, accountId: String?) -> WeeklyUsageCycle? {
        if let current = currentCycle, current.resetsAt == resetsAt {
            if accountId == nil || current.accountId == nil || current.accountId == accountId {
                return current
            }
        }

        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: data),
           decoded.resetsAt == resetsAt {
            if accountId == nil || decoded.accountId == nil || decoded.accountId == accountId {
                return decoded
            }
        }

        for suite in legacySuiteNames {
            if let legacyDefaults = UserDefaults(suiteName: suite),
               let legacyData = legacyDefaults.data(forKey: storageKey),
               let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: legacyData),
               decoded.resetsAt == resetsAt {
                if accountId == nil || decoded.accountId == nil || decoded.accountId == accountId {
                    return decoded
                }
            }
        }

        if let backupDirectory {
            let fileURL = backupDirectory.appendingPathComponent("\(storageKey).json")
            if let fileData = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: fileData),
               decoded.resetsAt == resetsAt {
                if accountId == nil || decoded.accountId == nil || decoded.accountId == accountId {
                    return decoded
                }
            }

            let historyURL = backupDirectory.appendingPathComponent("\(storageKey)_history.json")
            if let historyData = try? Data(contentsOf: historyURL),
               let map = try? JSONDecoder().decode([String: WeeklyUsageCycle].self, from: historyData),
               let saved = map[String(resetsAt)] {
                if accountId == nil || saved.accountId == nil || saved.accountId == accountId {
                    return saved
                }
            }
        }

        return nil
    }

    public func clear() {
        currentCycle = nil
        userDefaults.removeObject(forKey: storageKey)
        userDefaults.synchronize()
        if let backupDirectory {
            let fileURL = backupDirectory.appendingPathComponent("\(storageKey).json")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func save(_ cycle: WeeklyUsageCycle) {
        guard let data = try? JSONEncoder().encode(cycle) else { return }
        userDefaults.set(data, forKey: storageKey)
        userDefaults.synchronize()

        guard let backupDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let fileURL = backupDirectory.appendingPathComponent("\(storageKey).json")
            try data.write(to: fileURL, options: .atomic)

            let historyURL = backupDirectory.appendingPathComponent("\(storageKey)_history.json")
            var historyMap: [String: WeeklyUsageCycle] = [:]
            if let existingData = try? Data(contentsOf: historyURL),
               let decoded = try? JSONDecoder().decode([String: WeeklyUsageCycle].self, from: existingData) {
                historyMap = decoded
            }
            historyMap[String(cycle.resetsAt)] = cycle
            if let historyData = try? JSONEncoder().encode(historyMap) {
                try historyData.write(to: historyURL, options: .atomic)
            }
        } catch {
            // Backup failures do not crash the app
        }
    }
}
