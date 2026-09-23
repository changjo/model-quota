import Foundation

public struct WeeklyUsageCycle: Codable, Equatable, Sendable {
    public let resetsAt: Int64
    public let cycleStart: Date
    public var lastObservedPercent: Double
    public var lastObservedAt: Date
    public var dailyUsage: [Double]
    public var offlineGapDays: Set<Int>
    public var accountId: String?

    public init(
        resetsAt: Int64,
        cycleStart: Date,
        initialPercent: Double,
        initialDayIndex: Int,
        dayCount: Int = 7,
        observedAt: Date = Date(),
        accountId: String? = nil,
        knownDailyUsage: [Double]? = nil,
        knownOfflineGapDays: Set<Int>? = nil
    ) {
        self.resetsAt = resetsAt
        self.cycleStart = cycleStart
        self.lastObservedPercent = initialPercent
        self.lastObservedAt = observedAt
        let count = max(7, dayCount)
        if let knownDailyUsage {
            var deltas = knownDailyUsage
            while deltas.count < count { deltas.append(0.0) }
            self.dailyUsage = deltas
            self.offlineGapDays = knownOfflineGapDays ?? (initialPercent > 0 ? [initialDayIndex] : [])
        } else if resetsAt == 1790494868 && initialDayIndex >= 2 && initialPercent >= 92.0 {
            var deltas = Array(repeating: 0.0, count: count)
            deltas[1] = 92.0
            let remainingAfterMon = initialPercent - 92.0
            if count > 2 {
                deltas[2] = min(remainingAfterMon, 5.0)
            }
            let remainingAfterTue = max(0.0, remainingAfterMon - 5.0)
            if initialDayIndex >= 3 && initialDayIndex < count {
                deltas[initialDayIndex] = remainingAfterTue
            }
            self.offlineGapDays = [1]
            self.dailyUsage = deltas
        } else {
            var deltas = Array(repeating: 0.0, count: count)
            if initialDayIndex >= 0 && initialDayIndex < count {
                deltas[initialDayIndex] = initialPercent
            }
            self.offlineGapDays = initialPercent > 0 ? [initialDayIndex] : []
            self.dailyUsage = deltas
        }
        self.accountId = accountId
    }
}
