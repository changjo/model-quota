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
        accountId: String? = nil
    ) {
        self.resetsAt = resetsAt
        self.cycleStart = cycleStart
        self.lastObservedPercent = initialPercent
        self.lastObservedAt = observedAt
        let count = max(7, dayCount)
        var deltas = Array(repeating: 0.0, count: count)
        if initialDayIndex >= 0 && initialDayIndex < count {
            deltas[initialDayIndex] = initialPercent
        }
        self.dailyUsage = deltas
        self.offlineGapDays = initialPercent > 0 ? [initialDayIndex] : []
        self.accountId = accountId
    }
}
