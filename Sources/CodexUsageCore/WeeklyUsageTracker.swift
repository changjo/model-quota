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
            self.currentCycle = decoded
        }
    }

    public func record(snapshot: UsageSnapshot, now: Date = Date()) {
        guard let weeklyQuota = snapshot.quotas.first(where: { $0.durationMinutes == 10080 }),
              let resetsAt = weeklyQuota.window.resetsAt else {
            return
        }
        record(resetsAt: resetsAt, usedPercent: weeklyQuota.usedPercent, now: now)
    }

    public func record(resetsAt: Int64, usedPercent: Double, now: Date = Date()) {
        let cycleDurationSeconds: TimeInterval = 7 * 86400
        let cycleStart = Date(timeIntervalSince1970: TimeInterval(resetsAt) - cycleDurationSeconds)
        let elapsed = max(0, now.timeIntervalSince(cycleStart))
        let currentDayIndex = min(6, max(0, Int(elapsed / 86400)))

        if currentCycle == nil || currentCycle?.resetsAt != resetsAt {
            let newCycle = WeeklyUsageCycle(
                resetsAt: resetsAt,
                cycleStart: cycleStart,
                initialPercent: usedPercent,
                initialDayIndex: currentDayIndex,
                observedAt: now
            )
            self.currentCycle = newCycle
            save(newCycle)
            return
        }

        guard var cycle = currentCycle else { return }

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
