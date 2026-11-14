import Foundation

public struct ProviderUsageItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let summaryValue: String
    public let isRefreshing: Bool
    public let hasError: Bool

    public init(
        id: String,
        label: String,
        summaryValue: String,
        isRefreshing: Bool = false,
        hasError: Bool = false
    ) {
        self.id = id
        self.label = label
        self.summaryValue = summaryValue
        self.isRefreshing = isRefreshing
        self.hasError = hasError
    }

    public var displayText: String {
        "\(label) \(summaryValue)"
    }

    /// Spoken form: the values are remaining capacity, and "?" / "…" are not numbers.
    public var accessibilityText: String {
        switch summaryValue {
        case "?": return "\(label): unavailable"
        case "…": return "\(label): checking"
        default: return "\(label): \(summaryValue) remaining"
        }
    }
}
