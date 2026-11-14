import Foundation

/// Parses the ISO-8601 timestamps the provider CLIs emit, with or without fractional seconds.
/// Returns nil for anything else rather than inventing a date.
enum ISODate {
    // ISO8601DateFormatter is thread-safe, so the formatters are shared.
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}
