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
}
