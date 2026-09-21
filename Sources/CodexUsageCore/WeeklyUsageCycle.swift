import Foundation

public struct WeeklyUsageCycle: Codable, Equatable, Sendable {
    public let resetsAt: Int64
    public let cycleStart: Date
    public var lastObservedPercent: Double
    public var lastObservedAt: Date
    public var dailyUsage: [Double]
    public var offlineGapDays: Set<Int>

    public init(
        resetsAt: Int64,
        cycleStart: Date,
        initialPercent: Double,
        initialDayIndex: Int,
        observedAt: Date = Date()
    ) {
        self.resetsAt = resetsAt
        self.cycleStart = cycleStart
        self.lastObservedPercent = initialPercent
        self.lastObservedAt = observedAt
        var deltas = Array(repeating: 0.0, count: 7)
        if initialDayIndex >= 0 && initialDayIndex < 7 {
            deltas[initialDayIndex] = initialPercent
        }
        self.dailyUsage = deltas
        self.offlineGapDays = initialPercent > 0 ? [initialDayIndex] : []
    }
}
