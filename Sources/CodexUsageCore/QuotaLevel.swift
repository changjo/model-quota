import Foundation

/// Shared percent math so every provider presents remaining capacity the same way.
public enum QuotaMath {
    /// Remaining percent rounded down so the app never overstates what is left, clamped to 0...100.
    /// A tiny epsilon absorbs binary floating-point error (0.29 * 100 == 28.999999999999996).
    public static func remainingPercent(remaining: Double) -> Int {
        guard remaining.isFinite else { return 0 }
        return Int(min(100, max(0, (remaining + 1e-9).rounded(.down))))
    }
}

/// How urgently a remaining percentage should be presented.
public enum QuotaLevel: Equatable, Sendable {
    case normal, low, critical

    public static let lowThreshold = 25
    public static let criticalThreshold = 10

    public init(remainingPercent: Int) {
        if remainingPercent <= Self.criticalThreshold { self = .critical }
        else if remainingPercent <= Self.lowThreshold { self = .low }
        else { self = .normal }
    }
}
