import Foundation

public struct GeminiUsageSnapshot: Equatable, Sendable {
    public struct Bucket: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let description: String?
        public let window: String
        public let remainingFraction: Double
        public let resetTime: Date?

        public var remainingPercent: Int {
            QuotaMath.remainingPercent(remaining: remainingFraction * 100)
        }

        public var usedPercent: Double {
            max(0, min(100, (1.0 - remainingFraction) * 100))
        }

        /// A title in the same scheme as the other providers ("Weekly Limit", "5-Hour Limit");
        /// agy's own names read "Weekly Limit Remaining", which clashes with the "% remaining" figure.
        public var title: String {
            switch window {
            case "5h": return "5-Hour Limit"
            case "weekly": return "Weekly Limit"
            default:
                let suffix = " Remaining"
                return name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
            }
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            window = try container.decode(String.self, forKey: .window)
            remainingFraction = try container.decode(Double.self, forKey: .remainingFraction)
            // An unreadable timestamp means "unknown", never "now" (which would fake a reset).
            resetTime = ISODate.parse(try? container.decodeIfPresent(String.self, forKey: .resetTime))
        }
    }

    public struct ModelGroup: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let description: String?
        public let buckets: [Bucket]

        public init(name: String, description: String? = nil, buckets: [Bucket]) {
            self.name = name
            self.description = description
            self.buckets = buckets
        }

        enum CodingKeys: String, CodingKey { case name, description, buckets }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            // One malformed bucket (possibly in an unrelated group) must not hide the rest.
            buckets = (try container.decodeIfPresent([Lenient<Bucket>].self, forKey: .buckets) ?? []).compactMap(\.value)
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

    /// The weekly bucket, else the 5-hour bucket; nil when agy reported no Gemini quota.
    public var primaryRemainingPercent: Int? {
        weeklyBucket?.remainingPercent ?? fiveHourBucket?.remainingPercent
    }

    public var fiveHourRemainingPercent: Int? {
        fiveHourBucket?.remainingPercent
    }

    public func formattedValue(for mode: MenuBarDisplayMode) -> String {
        let session = fiveHourBucket?.remainingPercent
        let weekly = weeklyBucket?.remainingPercent
        let value: String?
        switch mode {
        case .both:
            value = [session, weekly].compactMap { $0 }.map { "\($0)%" }.joined(separator: " / ")
        case .weeklyOnly:
            value = (weekly ?? session).map { "\($0)%" }
        case .sessionOnly:
            value = (session ?? weekly).map { "\($0)%" }
        case .mostRestrictive:
            value = [session, weekly].compactMap { $0 }.min().map { "\($0)%" }
        }
        // No Gemini quota is "unknown", never a made-up 100%.
        guard let value, !value.isEmpty else { return "?" }
        return value
    }

    public static func decode(from data: Data) throws -> GeminiUsageSnapshot {
        struct AgyEnvelope: Decodable {
            struct Command: Decodable {
                struct DataPayload: Decodable {
                    let groups: [Lenient<ModelGroup>]?
                }
                let data: DataPayload?
            }
            let command: Command?
        }

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(AgyEnvelope.self, from: data)
        // Groups whose buckets were all unreadable are dropped instead of shown as empty headings.
        guard let groups = envelope.command?.data?.groups?.compactMap(\.value).filter({ !$0.buckets.isEmpty }),
              !groups.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "No groups found in agy usage output"))
        }

        return GeminiUsageSnapshot(groups: groups)
    }

    /// Classifies a failed `agy` run. agy reports failures as a JSON envelope on stdout
    /// (`{"status":"ERROR","error":"…"}`); stderr is only consulted when that is missing.
    public static func failure(stdout: Data, stderr: Data) -> UsageError {
        struct ErrorEnvelope: Decodable {
            let status: String?
            let error: String?
        }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: stdout),
           let message = envelope.error, !message.isEmpty {
            return UsageError.classifyCLIFailure(message)
        }
        return UsageError.classifyCLIFailure(String(decoding: stderr, as: UTF8.self))
    }
}
