import XCTest
@testable import CodexUsageCore

final class ClaudeUsageSnapshotTests: XCTestCase {
    func testDecodeStreamJsonResponse() throws {
        let streamJson = """
        {"type":"system","message":"Initializing Claude Code"}
        {"type":"control_response","response":{"subtype":"success","response":{"subscription_type":"Claude Pro","rate_limits_available":true,"rate_limits":{"five_hour":{"resets_at":"2026-10-15T11:00:00.000Z","utilization":35.0},"seven_day":{"resets_at":"2026-10-21T06:00:00.000Z","utilization":68.0},"seven_day_breakdown":{"rows":[{"display_name":"Claude 3.7 Sonnet","key":"claude-3-7-sonnet","percent":60.0},{"display_name":"Claude 3.5 Haiku","key":"claude-3-5-haiku","percent":8.0}]}}}}}
        """

        let snapshot = try ClaudeUsageSnapshot.decode(from: Data(streamJson.utf8))

        XCTAssertEqual(snapshot.subscriptionType, "Claude Pro")
        XCTAssertTrue(snapshot.rateLimitsAvailable)

        let fiveHour = try XCTUnwrap(snapshot.fiveHour)
        XCTAssertEqual(fiveHour.utilization, 35.0)
        XCTAssertEqual(fiveHour.remainingPercent, 65)
        XCTAssertEqual(fiveHour.usedPercent, 35.0)
        XCTAssertNotNil(fiveHour.resetsAt)

        let sevenDay = try XCTUnwrap(snapshot.sevenDay)
        XCTAssertEqual(sevenDay.utilization, 68.0)
        XCTAssertEqual(sevenDay.remainingPercent, 32)
        XCTAssertEqual(sevenDay.usedPercent, 68.0)
        XCTAssertNotNil(sevenDay.resetsAt)

        XCTAssertEqual(snapshot.breakdownRows.count, 2)
        XCTAssertEqual(snapshot.breakdownRows[0].displayName, "Claude 3.7 Sonnet")
        XCTAssertEqual(snapshot.breakdownRows[0].percent, 60.0)

        // Primary remaining percent is weekly limit if present
        XCTAssertEqual(snapshot.primaryRemainingPercent, 32)
    }

    func testDecodeErrorResponse() {
        let streamJson = """
        {"type":"control_response","response":{"subtype":"error","error":"Authentication required. Please run claude login."}}
        """

        XCTAssertThrowsError(try ClaudeUsageSnapshot.decode(from: Data(streamJson.utf8))) { error in
            XCTAssertEqual(error as? UsageError, UsageError.loginRequired)
        }
    }

    func testWindowPercentCalculations() {
        let windowZero = ClaudeUsageSnapshot.Window(utilization: 0, resetsAt: nil)
        XCTAssertEqual(windowZero.remainingPercent, 100)
        XCTAssertEqual(windowZero.usedPercent, 0)
        XCTAssertEqual(windowZero.remainingFraction, 1.0)

        let windowFull = ClaudeUsageSnapshot.Window(utilization: 100, resetsAt: nil)
        XCTAssertEqual(windowFull.remainingPercent, 0)
        XCTAssertEqual(windowFull.usedPercent, 100)
        XCTAssertEqual(windowFull.remainingFraction, 0.0)

        let windowOver = ClaudeUsageSnapshot.Window(utilization: 105, resetsAt: nil)
        XCTAssertEqual(windowOver.remainingPercent, 0)
        XCTAssertEqual(windowOver.usedPercent, 100)
        XCTAssertEqual(windowOver.remainingFraction, 0.0)
    }
}
