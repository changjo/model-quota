import Foundation

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case both = "both"
    case weeklyOnly = "weeklyOnly"
    case sessionOnly = "sessionOnly"
    case mostRestrictive = "mostRestrictive"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .both:
            return "Both (Session / Weekly)"
        case .weeklyOnly:
            return "Weekly only"
        case .sessionOnly:
            return "Session only (5h)"
        case .mostRestrictive:
            return "Most restrictive (lowest %)"
        }
    }
}
