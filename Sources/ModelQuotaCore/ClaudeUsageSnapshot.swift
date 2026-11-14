import Foundation

public struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let utilization: Double
        public let resetsAt: Date?

        public var remainingPercent: Int {
            QuotaMath.remainingPercent(remaining: 100.0 - utilization)
        }

        public var remainingFraction: Double {
            max(0, min(1.0, (100.0 - utilization) / 100.0))
        }

        public var usedPercent: Double {
            max(0, min(100, utilization))
        }

        public init(utilization: Double, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    public struct BreakdownRow: Codable, Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let displayName: String
        public let percent: Double

        public init(key: String, displayName: String, percent: Double) {
            self.key = key
            self.displayName = displayName
            self.percent = percent
        }

        enum CodingKeys: String, CodingKey {
            case key
            case displayName = "display_name"
            case percent
        }
    }

    public let subscriptionType: String?
    public let rateLimitsAvailable: Bool
    public let fiveHour: Window?
    public let sevenDay: Window?
    public let breakdownRows: [BreakdownRow]
    public let fetchedAt: Date

    public init(
        subscriptionType: String? = nil,
        rateLimitsAvailable: Bool = true,
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        breakdownRows: [BreakdownRow] = [],
        fetchedAt: Date = Date()
    ) {
        self.subscriptionType = subscriptionType
        self.rateLimitsAvailable = rateLimitsAvailable
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.breakdownRows = breakdownRows
        self.fetchedAt = fetchedAt
    }

    /// The weekly window, else the session window; nil when the CLI reported neither.
    public var primaryRemainingPercent: Int? {
        sevenDay?.remainingPercent ?? fiveHour?.remainingPercent
    }

    public func formattedValue(for mode: MenuBarDisplayMode) -> String {
        let session = fiveHour?.remainingPercent
        let weekly = sevenDay?.remainingPercent
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
        // No reported window is "unknown", never a made-up 100%.
        guard let value, !value.isEmpty else { return "?" }
        return value
    }

    public static func decode(from data: Data) throws -> ClaudeUsageSnapshot {
        struct StreamControlEnvelope: Decodable {
            let type: String?
            let response: ControlResponse?
        }

        struct ControlResponse: Decodable {
            let subtype: String?
            let error: String?
            let response: ResponsePayload?
        }

        struct ResponsePayload: Decodable {
            let subscription_type: String?
            let rate_limits_available: Bool?
            let rate_limits: RateLimitsPayload?
        }

        struct RateLimitsPayload: Decodable {
            let five_hour: WindowPayload?
            let seven_day: WindowPayload?
            let seven_day_breakdown: BreakdownPayload?
        }

        struct WindowPayload: Decodable {
            let utilization: Double?
            let resets_at: String?

            enum CodingKeys: String, CodingKey { case utilization, resets_at }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
                // An unexpected timestamp type means "unknown reset", not an unreadable response.
                resets_at = try? container.decodeIfPresent(String.self, forKey: .resets_at)
            }
        }

        struct BreakdownPayload: Decodable {
            let rows: [Lenient<BreakdownRow>]?
        }

        let decoder = JSONDecoder()

        // The stream-json format sends JSON objects separated by newlines.
        // Try decoding line by line first to find the control_response.
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.split(whereSeparator: \.isNewline)
            for line in lines {
                guard let lineData = line.data(using: .utf8) else { continue }
                if let env = try? decoder.decode(StreamControlEnvelope.self, from: lineData),
                   env.type == "control_response" || env.response != nil {
                    if let ctrl = env.response {
                        if ctrl.subtype == "error" {
                            throw UsageError.classifyCLIFailure(ctrl.error ?? "")
                        }
                        if let payload = ctrl.response {
                            let fiveHour: Window?
                            if let fh = payload.rate_limits?.five_hour, let u = fh.utilization {
                                fiveHour = Window(utilization: u, resetsAt: ISODate.parse(fh.resets_at))
                            } else {
                                fiveHour = nil
                            }
                            let sevenDay: Window?
                            if let sd = payload.rate_limits?.seven_day, let u = sd.utilization {
                                sevenDay = Window(utilization: u, resetsAt: ISODate.parse(sd.resets_at))
                            } else {
                                sevenDay = nil
                            }
                            return ClaudeUsageSnapshot(
                                subscriptionType: payload.subscription_type,
                                rateLimitsAvailable: payload.rate_limits_available ?? true,
                                fiveHour: fiveHour,
                                sevenDay: sevenDay,
                                breakdownRows: payload.rate_limits?.seven_day_breakdown?.rows?.compactMap(\.value) ?? []
                            )
                        }
                    }
                }
            }
        }

        throw UsageError.invalidResponse
    }
}
