import Foundation

public struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let utilization: Double
        public let resetsAt: Date?

        public var remainingPercent: Int {
            max(0, min(100, Int((100.0 - utilization).rounded())))
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

    public var primaryRemainingPercent: Int {
        sevenDay?.remainingPercent ?? (fiveHour?.remainingPercent ?? 100)
    }

    public func formattedValue(for mode: MenuBarDisplayMode) -> String {
        let session = fiveHour
        let weekly = sevenDay

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
            let resets_at: Date?
        }

        struct BreakdownPayload: Decodable {
            let rows: [BreakdownRow]?
        }

        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = isoFormatter.date(from: dateStr) ?? standardFormatter.date(from: dateStr) {
                return date
            }
            return Date()
        }

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
                            if (ctrl.error ?? "").contains("login") || (ctrl.error ?? "").contains("auth") {
                                throw UsageError.loginRequired
                            }
                            throw UsageError.requestFailed
                        }
                        if let payload = ctrl.response {
                            let fiveHour: Window?
                            if let fh = payload.rate_limits?.five_hour, let u = fh.utilization {
                                fiveHour = Window(utilization: u, resetsAt: fh.resets_at)
                            } else {
                                fiveHour = nil
                            }
                            let sevenDay: Window?
                            if let sd = payload.rate_limits?.seven_day, let u = sd.utilization {
                                sevenDay = Window(utilization: u, resetsAt: sd.resets_at)
                            } else {
                                sevenDay = nil
                            }
                            return ClaudeUsageSnapshot(
                                subscriptionType: payload.subscription_type,
                                rateLimitsAvailable: payload.rate_limits_available ?? true,
                                fiveHour: fiveHour,
                                sevenDay: sevenDay,
                                breakdownRows: payload.rate_limits?.seven_day_breakdown?.rows ?? []
                            )
                        }
                    }
                }
            }
        }

        throw UsageError.invalidResponse
    }
}
