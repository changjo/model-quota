import Foundation

public struct UsageSnapshot: Decodable, Equatable, Sendable {
    public let accountId: String?
    public let rateLimits: RateLimitBucket
    public let rateLimitsByLimitId: [String: RateLimitBucket]?
    public let ordinaryUsageAllowed: Bool?
    public let rateLimitResetCredits: ResetCredits?

    public var bucket: RateLimitBucket? {
        if let codex = rateLimitsByLimitId?["codex"] { return codex }
        return rateLimits.limitId == nil || rateLimits.limitId == "codex" ? rateLimits : nil
    }
    public var resetCredits: ResetCredits? { rateLimitResetCredits }
    public var quotas: [Quota] {
        guard let bucket else { return [] }
        return [("primary", bucket.primary), ("secondary", bucket.secondary)]
            .compactMap { id, window in window.map { Quota(id: id, window: $0) } }
            .sorted {
                let left = $0.durationMinutes ?? Int.max
                let right = $1.durationMinutes ?? Int.max
                return left == right ? $0.id < $1.id : left < right
            }
    }
    public var menuBarTitle: String {
        let values = quotas.map { "\($0.remainingPercent)%" }
        return values.isEmpty ? "Codex ?" : "Codex " + values.joined(separator: " / ")
    }

    public func formattedValue(for mode: MenuBarDisplayMode) -> String {
        guard !quotas.isEmpty else { return "?" }
        let session = quotas.first(where: { ($0.durationMinutes ?? Int.max) < 1440 })
        let weekly = quotas.first(where: { ($0.durationMinutes ?? 0) >= 1440 })

        switch mode {
        case .both:
            return quotas.map { "\($0.remainingPercent)%" }.joined(separator: " / ")
        case .weeklyOnly:
            if let weekly { return "\(weekly.remainingPercent)%" }
            if let session { return "\(session.remainingPercent)%" }
            return "\(quotas[0].remainingPercent)%"
        case .sessionOnly:
            if let session { return "\(session.remainingPercent)%" }
            if let weekly { return "\(weekly.remainingPercent)%" }
            return "\(quotas[0].remainingPercent)%"
        case .mostRestrictive:
            let minPercent = quotas.map(\.remainingPercent).min() ?? 100
            return "\(minPercent)%"
        }
    }
}

public struct RateLimitBucket: Decodable, Equatable, Sendable {
    public let limitId: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
    public let credits: Credits?
    public let planType: String?
    public let rateLimitReachedType: String?
    public let spendControlReached: Bool?
}

public struct RateLimitWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Int64?
}

public struct Credits: Decodable, Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public var display: String {
        if unlimited { return "Unlimited" }
        if !hasCredits { return "None" }
        return balance.map { "\($0) credits" } ?? "Available"
    }
}

public struct ResetCredits: Decodable, Equatable, Sendable {
    public let availableCount: Int
}

public struct Quota: Identifiable, Equatable, Sendable {
    public let id: String
    public let window: RateLimitWindow
    public var durationMinutes: Int? {
        guard let minutes = window.windowDurationMins, minutes > 0 else { return nil }
        return minutes
    }
    public var usedPercent: Double { min(100, max(0, window.usedPercent)) }
    public var remainingFraction: Double { (100 - usedPercent) / 100 }
    public var remainingPercent: Int { Int((100 - usedPercent).rounded(.down)) }
    public var resetDate: Date? { window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public var title: String {
        switch durationMinutes {
        case 300: return "5-Hour Limit"
        case 10080: return "Weekly Limit"
        case .some(let minutes) where minutes.isMultiple(of: 1440): return "\(minutes / 1440)-Day Limit"
        case .some(let minutes) where minutes.isMultiple(of: 60): return "\(minutes / 60)-Hour Limit"
        case .some(let minutes): return "\(minutes)-Minute Limit"
        case .none: return "Usage Limit"
        }
    }
}
