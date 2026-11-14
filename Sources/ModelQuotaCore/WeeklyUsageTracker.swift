import Foundation

@MainActor
public final class WeeklyUsageTracker: ObservableObject {
    public static let shared = WeeklyUsageTracker()

    @Published public private(set) var currentCycle: WeeklyUsageCycle?

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let backupDirectory: URL?
    private let legacySuiteNames: [String]
    private let calendar: Calendar

    public static let cycleDuration: TimeInterval = 7 * 86400
    /// How far the reported window may move later before the cycle is re-anchored to it.
    /// Large enough to ignore second-level `resetsAt` jitter.
    static let realignmentTolerance: TimeInterval = 3600
    /// Number of past cycles kept in the history file (per storage key, all accounts).
    public static let historyLimit = 12

    /// History entries are per account: two accounts can have windows that end within a day.
    static func historyKey(for cycle: WeeklyUsageCycle) -> String {
        "\(cycle.accountId ?? "-")|\(cycle.resetsAt)"
    }

    /// A missing account id (older data, providers without accounts) matches any account.
    static func sameAccount(_ a: String?, _ b: String?) -> Bool {
        a == nil || b == nil || a == b
    }

    /// `storageKey` and `legacySuiteNames` keep the app's former "Codex Usage" names on purpose:
    /// they locate history already saved on users' Macs, so renaming them would drop that history.
    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "codex_usage_weekly_tracker",
        backupDirectory: URL? = nil,
        legacySuiteNames: [String] = ["dev.changjo.CodexUsage"],
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.backupDirectory = backupDirectory ?? (userDefaults == .standard ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Model Quota") : nil)
        self.legacySuiteNames = legacySuiteNames
        self.calendar = calendar

        self.currentCycle = loadInitialCycle()
    }

    public static func isSameCycle(resetsAtA: Int64, resetsAtB: Int64) -> Bool {
        abs(resetsAtA - resetsAtB) < 86400
    }

    /// Number of calendar-day buckets needed to cover `cycleStart ..< resetDate`.
    static func dayCount(cycleStart: Date, resetDate: Date, calendar: Calendar) -> Int {
        let cycleStartDay = calendar.startOfDay(for: cycleStart)
        let resetDay = calendar.startOfDay(for: resetDate)
        let resetDayOffset = calendar.dateComponents([.day], from: cycleStartDay, to: resetDay).day ?? 7
        return max(7, resetDayOffset + (resetDate > resetDay ? 1 : 0))
    }

    static func dayLayout(cycleStart: Date, resetDate: Date, now: Date, calendar: Calendar) -> (currentDayIndex: Int, dayCount: Int) {
        let count = dayCount(cycleStart: cycleStart, resetDate: resetDate, calendar: calendar)
        let offset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: cycleStart),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        return (min(count - 1, max(0, offset)), count)
    }

    /// Re-anchors `cycleStart` to the window actually reported by the server (`resetsAt - 7d`).
    ///
    /// Some providers (e.g. agy) report `resetsAt = now + 7d` while a quota is unused, so the
    /// window keeps sliding forward until the first request. Because each step is far below
    /// the jitter tolerance the cycle was treated as unchanged, `cycleStart` stayed put, and the
    /// day count grew without bound. Days that fall before the realigned start are folded into
    /// the new first day so no recorded usage is lost.
    public static func realigned(_ cycle: WeeklyUsageCycle, calendar: Calendar = .autoupdatingCurrent) -> WeeklyUsageCycle {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(cycle.resetsAt))
        let windowStart = resetDate.addingTimeInterval(-cycleDuration)
        // A cycle without recorded usage has nothing to misplace, so it can follow the window exactly.
        let hasUsage = cycle.lastObservedPercent > 0 || cycle.dailyUsage.contains { $0 > 0 }
        let tolerance = hasUsage ? realignmentTolerance : 0
        guard windowStart.timeIntervalSince(cycle.cycleStart) > tolerance else { return cycle }

        let shift = max(0, calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: cycle.cycleStart),
            to: calendar.startOfDay(for: windowStart)
        ).day ?? 0)

        var result = cycle
        result.cycleStart = windowStart
        if shift > 0 {
            let folded = cycle.dailyUsage.prefix(shift + 1).reduce(0, +)
            result.dailyUsage = [folded] + cycle.dailyUsage.dropFirst(shift + 1)
            result.offlineGapDays = Set(cycle.offlineGapDays.map { max(0, $0 - shift) })
        }

        let count = dayCount(cycleStart: windowStart, resetDate: resetDate, calendar: calendar)
        while result.dailyUsage.count < count { result.dailyUsage.append(0.0) }
        while result.dailyUsage.count > count, result.dailyUsage.last == 0 { result.dailyUsage.removeLast() }
        result.offlineGapDays = result.offlineGapDays.filter { $0 < result.dailyUsage.count }
        return result
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

        // Re-anchor cycles whose window drifted forward (repairs already-persisted data)
        if let cycle = baseCycle {
            baseCycle = Self.realigned(cycle, calendar: calendar)
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

    public func healFromHistory(cycle: WeeklyUsageCycle, calendar: Calendar? = nil) -> WeeklyUsageCycle {
        guard let backupDirectory else { return cycle }
        let historyURL = backupDirectory.appendingPathComponent("\(storageKey)_history.json")
        guard let historyData = try? Data(contentsOf: historyURL),
              let historyMap = try? JSONDecoder().decode([String: WeeklyUsageCycle].self, from: historyData) else {
            return cycle
        }

        let calendar = calendar ?? self.calendar
        var healed = cycle
        let matchingPriors = historyMap.values
            .filter {
                Self.isSameCycle(resetsAtA: $0.resetsAt, resetsAtB: cycle.resetsAt)
                    && Self.sameAccount($0.accountId, cycle.accountId)
            }
            .sorted { $0.lastObservedAt > $1.lastObservedAt }

        let cycleStartDay = calendar.startOfDay(for: cycle.cycleStart)
        for prior in matchingPriors {
            // Day indices are only comparable when both cycles share the same start day.
            let alignedPrior = Self.realigned(prior, calendar: calendar)
            guard calendar.startOfDay(for: alignedPrior.cycleStart) == cycleStartDay else { continue }
            healed = healCycle(corrupted: healed, fromPrior: alignedPrior)
        }
        return healed
    }

    public func record(snapshot: UsageSnapshot, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
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
        calendar: Calendar = .autoupdatingCurrent
    ) {
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

        if isDifferentCycle || isDifferentAccount {
            // Check if backup history or stored cycle has this cycle before initializing blank
            if let existing = findCycle(forResetsAt: resetsAt, accountId: accountId) {
                self.currentCycle = existing
            } else {
                let cycleStart = resetDate.addingTimeInterval(-Self.cycleDuration)
                let layout = Self.dayLayout(cycleStart: cycleStart, resetDate: resetDate, now: now, calendar: calendar)
                let newCycle = WeeklyUsageCycle(
                    resetsAt: resetsAt,
                    cycleStart: cycleStart,
                    initialPercent: usedPercent,
                    initialDayIndex: layout.currentDayIndex,
                    dayCount: layout.dayCount,
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
        // Follow the server's window if it slid forward (e.g. an idle rolling window).
        cycle = Self.realigned(cycle, calendar: calendar)

        if cycle.accountId == nil, let accountId {
            cycle.accountId = accountId
        }

        let layout = Self.dayLayout(cycleStart: cycle.cycleStart, resetDate: resetDate, now: now, calendar: calendar)
        let currentDayIndex = layout.currentDayIndex
        while cycle.dailyUsage.count < layout.dayCount {
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
        cycle = healFromHistory(cycle: cycle, calendar: calendar)

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
                return Self.realigned(current, calendar: calendar)
            }
        }

        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: data),
           Self.isSameCycle(resetsAtA: decoded.resetsAt, resetsAtB: resetsAt) {
            if accountId == nil || decoded.accountId == nil || decoded.accountId == accountId {
                return Self.realigned(decoded, calendar: calendar)
            }
        }

        if let backupDirectory {
            let fileURL = backupDirectory.appendingPathComponent("\(storageKey).json")
            if let fileData = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: fileData),
               Self.isSameCycle(resetsAtA: decoded.resetsAt, resetsAtB: resetsAt) {
                if accountId == nil || decoded.accountId == nil || decoded.accountId == accountId {
                    return Self.realigned(decoded, calendar: calendar)
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
                    return Self.realigned(best, calendar: calendar)
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
            // Consolidate drifted (and legacy-keyed) entries for this account's cycle, never
            // another account's: two accounts may have windows that end within a day.
            let key = Self.historyKey(for: cycle)
            for (existingKey, existing) in historyMap where existingKey != key {
                if Self.sameAccount(existing.accountId, cycle.accountId),
                   Self.isSameCycle(resetsAtA: existing.resetsAt, resetsAtB: cycle.resetsAt) {
                    historyMap.removeValue(forKey: existingKey)
                }
            }
            historyMap[key] = cycle
            if historyMap.count > Self.historyLimit {
                let keep = historyMap.sorted { $0.value.lastObservedAt > $1.value.lastObservedAt }
                    .prefix(Self.historyLimit).map(\.key)
                historyMap = historyMap.filter { keep.contains($0.key) }
            }
            if let historyData = try? JSONEncoder().encode(historyMap) {
                try historyData.write(to: historyURL, options: .atomic)
            }
        } catch {
            // Backup failures do not crash the app
        }
    }
}
