import Foundation

public struct GeminiUsageSnapshot: Codable, Equatable, Sendable {
    public struct Bucket: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let description: String?
        public let window: String
        public let remainingFraction: Double
        public let resetTime: Date?

        public var remainingPercent: Int {
            Int((remainingFraction * 100).rounded())
        }

        public var usedPercent: Double {
            max(0, min(100, (1.0 - remainingFraction) * 100))
        }

        public init(
            id: String,
            name: String,
            description: String? = nil,
            window: String,
            remainingFraction: Double,
            resetTime: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.window = window
            self.remainingFraction = remainingFraction
            self.resetTime = resetTime
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case window
            case remainingFraction = "remaining_fraction"
            case resetTime = "reset_time"
        }
    }

    public struct ModelGroup: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let description: String?
        public let buckets: [Bucket]

        public init(name: String, description: String? = nil, buckets: [Bucket]) {
            self.name = name
            self.description = description
            self.buckets = buckets
        }
    }

    public let groups: [ModelGroup]
    public let fetchedAt: Date

    public init(groups: [ModelGroup], fetchedAt: Date = Date()) {
        self.groups = groups
        self.fetchedAt = fetchedAt
    }

    public var geminiGroup: ModelGroup? {
        groups.first(where: { $0.name.localizedCaseInsensitiveContains("Gemini") })
    }

    public var weeklyBucket: Bucket? {
        geminiGroup?.buckets.first(where: { $0.window == "weekly" || $0.id.contains("weekly") })
    }

    public var fiveHourBucket: Bucket? {
        geminiGroup?.buckets.first(where: { $0.window == "5h" || $0.id.contains("5h") })
    }

    public var primaryRemainingPercent: Int {
        weeklyBucket?.remainingPercent ?? (fiveHourBucket?.remainingPercent ?? 100)
    }

    public var fiveHourRemainingPercent: Int? {
        fiveHourBucket?.remainingPercent
    }

    public func formattedValue(for mode: MenuBarDisplayMode) -> String {
        let session = fiveHourBucket
        let weekly = weeklyBucket

        switch mode {
        case .both:
            if let s = session, let w = weekly {
                return "\(s.remainingPercent)% / \(w.remainingPercent)%"
            } else if let w = weekly {
                return "\(w.remainingPercent)%"
            } else if let s = session {
                return "\(s.remainingPercent)%"
            }
            return "\(primaryRemainingPercent)%"
        case .weeklyOnly:
            if let w = weekly { return "\(w.remainingPercent)%" }
            if let s = session { return "\(s.remainingPercent)%" }
            return "\(primaryRemainingPercent)%"
        case .sessionOnly:
            if let s = session { return "\(s.remainingPercent)%" }
            if let w = weekly { return "\(w.remainingPercent)%" }
            return "\(primaryRemainingPercent)%"
        case .mostRestrictive:
            if let s = session, let w = weekly {
                return "\(min(s.remainingPercent, w.remainingPercent))%"
            }
            return "\(primaryRemainingPercent)%"
        }
    }

    public static func decode(from data: Data) throws -> GeminiUsageSnapshot {
        struct AgyEnvelope: Decodable {
            struct Command: Decodable {
                struct DataPayload: Decodable {
                    let groups: [ModelGroup]?
                }
                let data: DataPayload?
            }
            let command: Command?
        }

        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = formatter.date(from: dateStr) {
                return date
            }
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fallbackFormatter.date(from: dateStr) {
                return date
            }
            return Date()
        }

        let envelope = try decoder.decode(AgyEnvelope.self, from: data)
        guard let groups = envelope.command?.data?.groups, !groups.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "No groups found in agy usage output"))
        }

        return GeminiUsageSnapshot(groups: groups)
    }
}
