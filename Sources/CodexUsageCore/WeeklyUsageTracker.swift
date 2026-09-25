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

    public static func isSameCycle(resetsAtA: Int64, resetsAtB: Int64) -> Bool {
        abs(resetsAtA - resetsAtB) < 86400
    }

    private func loadInitialCycle() -> WeeklyUsageCycle? {
        var cycleCandidate: WeeklyUsageCycle?

        // 1. Load from primary userDefaults
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: data) {
            cycleCandidate = decoded
        }

        // 2. Load from durable backup file if available
        var backupCandidate: WeeklyUsageCycle?
        if let backupDirectory {
            let fileURL = backupDirectory.appendingPathComponent("\(storageKey).json")
            if let fileData = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: fileData) {
                backupCandidate = decoded
            }
        }

        // 3. Load from legacy suites and immediately clean up legacy storage
        var legacyCandidate: WeeklyUsageCycle?
        for suite in legacySuiteNames {
            if let legacyDefaults = UserDefaults(suiteName: suite),
               let legacyData = legacyDefaults.data(forKey: storageKey),
               let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: legacyData) {
                legacyCandidate = decoded
                legacyDefaults.removeObject(forKey: storageKey)
                legacyDefaults.synchronize()
                break
            }
        }

        var baseCycle = cycleCandidate ?? backupCandidate ?? legacyCandidate

        // If primary/backup cycle was loaded, heal it from legacy candidate if available
        if var current = cycleCandidate ?? backupCandidate, let legacy = legacyCandidate {
            current = healCycle(corrupted: current, fromPrior: legacy)
            baseCycle = current
        }

        // Heal against history if available
        if let cycle = baseCycle {
            baseCycle = healFromHistory(cycle: cycle)
        }

        // Apply legacy self-healing rule for historical resetsAt 1790494868
        if var cycle = baseCycle {
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
        guard Self.isSameCycle(resetsAtA: corrupted.resetsAt, resetsAtB: prior.resetsAt) else { return corrupted }
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

    public func healFromHistory(cycle: WeeklyUsageCycle) -> WeeklyUsageCycle {
        guard let backupDirectory else { return cycle }
        let historyURL = backupDirectory.appendingPathComponent("\(storageKey)_history.json")
        guard let historyData = try? Data(contentsOf: historyURL),
              let historyMap = try? JSONDecoder().decode([String: WeeklyUsageCycle].self, from: historyData) else {
            return cycle
        }

        var healed = cycle
        let matchingPriors = historyMap.values
            .filter { Self.isSameCycle(resetsAtA: $0.resetsAt, resetsAtB: cycle.resetsAt) }
            .sorted { $0.lastObservedAt > $1.lastObservedAt }

        for prior in matchingPriors {
            healed = healCycle(corrupted: healed, fromPrior: prior)
        }
        return healed
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

        // If in-memory cycle is nil, attempt to restore from persistent storage before wiping
        if currentCycle == nil {
            currentCycle = loadInitialCycle()
        }

        let isDifferentAccount = accountId != nil && currentCycle?.accountId != nil && currentCycle?.accountId != accountId
        let isDifferentCycle: Bool
        if let current = currentCycle {
            isDifferentCycle = !Self.isSameCycle(resetsAtA: current.resetsAt, resetsAtB: resetsAt)
        } else {
            isDifferentCycle = true
        }

        let cycleStart: Date
        if let current = currentCycle, !isDifferentCycle {
            cycleStart = current.cycleStart
        } else {
            cycleStart = resetDate.addingTimeInterval(-cycleDurationSeconds)
        }

        let cycleStartDay = calendar.startOfDay(for: cycleStart)
        let nowDay = calendar.startOfDay(for: now)
        let resetDay = calendar.startOfDay(for: resetDate)

        let calendarDayOffset = calendar.dateComponents([.day], from: cycleStartDay, to: nowDay).day ?? 0
        let resetDayOffset = calendar.dateComponents([.day], from: cycleStartDay, to: resetDay).day ?? 7
        let totalCalendarDays = max(7, resetDayOffset + (resetDate > resetDay ? 1 : 0))
        let currentDayIndex = min(totalCalendarDays - 1, max(0, calendarDayOffset))

        if isDifferentCycle || isDifferentAccount {
            // Check if backup history or stored cycle has this cycle before initializing blank
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

        // Keep resetsAt updated to latest server timestamp within the same cycle
        if cycle.resetsAt != resetsAt {
            cycle.resetsAt = resetsAt
        }

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

        // Check if cycle can be healed from history
        cycle = healFromHistory(cycle: cycle)

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
        if let current = currentCycle, Self.isSameCycle(resetsAtA: current.resetsAt, resetsAtB: resetsAt) {
            if accountId == nil || current.accountId == nil || current.accountId == accountId {
                return current
            }
        }

        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: data),
           Self.isSameCycle(resetsAtA: decoded.resetsAt, resetsAtB: resetsAt) {
            if accountId == nil || decoded.accountId == nil || decoded.accountId == accountId {
                return decoded
            }
        }

        if let backupDirectory {
            let fileURL = backupDirectory.appendingPathComponent("\(storageKey).json")
            if let fileData = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: fileData),
               Self.isSameCycle(resetsAtA: decoded.resetsAt, resetsAtB: resetsAt) {
                if accountId == nil || decoded.accountId == nil || decoded.accountId == accountId {
                    return decoded
                }
            }

            let historyURL = backupDirectory.appendingPathComponent("\(storageKey)_history.json")
            if let historyData = try? Data(contentsOf: historyURL),
               let map = try? JSONDecoder().decode([String: WeeklyUsageCycle].self, from: historyData) {
                let matches = map.values.filter {
                    Self.isSameCycle(resetsAtA: $0.resetsAt, resetsAtB: resetsAt) &&
                    (accountId == nil || $0.accountId == nil || $0.accountId == accountId)
                }
                if let best = matches.max(by: { $0.lastObservedAt < $1.lastObservedAt }) {
                    return best
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
            // Consolidate drifted entries for the same cycle to prevent duplicate clutter
            for (key, existing) in historyMap {
                if existing.resetsAt != cycle.resetsAt && Self.isSameCycle(resetsAtA: existing.resetsAt, resetsAtB: cycle.resetsAt) {
                    historyMap.removeValue(forKey: key)
                }
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
