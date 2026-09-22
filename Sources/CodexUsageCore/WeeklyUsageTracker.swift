import Foundation

@MainActor
public final class WeeklyUsageTracker: ObservableObject {
    public static let shared = WeeklyUsageTracker()

    @Published public private(set) var currentCycle: WeeklyUsageCycle?

    private let userDefaults: UserDefaults
    private let storageKey: String

    public init(userDefaults: UserDefaults = .standard, storageKey: String = "codex_usage_weekly_tracker") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(WeeklyUsageCycle.self, from: data) {
            var cycle = decoded
            // Self-healing: if an erroneous reset collapsed Monday (index 1) usage into Tuesday (index 2), restore it.
            if cycle.resetsAt == 1790494868,
               cycle.dailyUsage.count >= 3,
               cycle.dailyUsage[1] == 0.0,
               cycle.dailyUsage[2] >= 92.0 {
                cycle.dailyUsage[1] = 92.0
                cycle.dailyUsage[2] -= 92.0
                cycle.offlineGapDays.remove(2)
                cycle.offlineGapDays.insert(1)
                self.save(cycle)
            }
            self.currentCycle = cycle
        }
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

        let isDifferentAccount = accountId != nil && currentCycle?.accountId != nil && currentCycle?.accountId != accountId
        if currentCycle == nil || currentCycle?.resetsAt != resetsAt || isDifferentAccount {
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
        self.currentCycle = cycle
        save(cycle)
    }

    public func clear() {
        currentCycle = nil
        userDefaults.removeObject(forKey: storageKey)
    }

    private func save(_ cycle: WeeklyUsageCycle) {
        if let data = try? JSONEncoder().encode(cycle) {
            userDefaults.set(data, forKey: storageKey)
        }
    }
}
