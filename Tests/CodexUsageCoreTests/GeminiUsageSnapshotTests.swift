import XCTest
@testable import CodexUsageCore

final class GeminiUsageSnapshotTests: XCTestCase {
    func testDecodeAgyJsonSample() throws {
        let fixtureURL = Bundle.module.url(forResource: "agy-usage-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Tests/CodexUsageCoreTests/Fixtures/agy-usage-sample.json")
        let data = try Data(contentsOf: fixtureURL)
        let snapshot = try GeminiUsageSnapshot.decode(from: data)

        XCTAssertEqual(snapshot.groups.count, 2)

        let geminiGroup = try XCTUnwrap(snapshot.groups.first(where: { $0.name == "Gemini Models" }))
        XCTAssertEqual(geminiGroup.buckets.count, 2)

        let weeklyBucket = try XCTUnwrap(geminiGroup.buckets.first(where: { $0.id == "gemini-weekly" }))
        XCTAssertEqual(weeklyBucket.remainingPercent, 86)
        XCTAssertEqual(weeklyBucket.usedPercent, 14.0, accuracy: 0.5)
        XCTAssertEqual(weeklyBucket.window, "weekly")
        XCTAssertNotNil(weeklyBucket.resetTime)

        let fiveHourBucket = try XCTUnwrap(geminiGroup.buckets.first(where: { $0.id == "gemini-5h" }))
        XCTAssertEqual(fiveHourBucket.remainingPercent, 91)
        XCTAssertEqual(fiveHourBucket.usedPercent, 9.0, accuracy: 0.5)
        XCTAssertEqual(fiveHourBucket.window, "5h")

        // Primary summary bucket for menu bar
        XCTAssertEqual(snapshot.primaryRemainingPercent, 86) // weekly is primary limit
        XCTAssertEqual(snapshot.fiveHourRemainingPercent, 91)
    }

    func testClaudeAndGptGroupDecoding() throws {
        let fixtureURL = Bundle.module.url(forResource: "agy-usage-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Tests/CodexUsageCoreTests/Fixtures/agy-usage-sample.json")
        let data = try Data(contentsOf: fixtureURL)
        let snapshot = try GeminiUsageSnapshot.decode(from: data)

        let claudeGroup = try XCTUnwrap(snapshot.groups.first(where: { $0.name == "Claude and GPT models" }))
        XCTAssertEqual(claudeGroup.buckets.count, 2)
        let weekly = try XCTUnwrap(claudeGroup.buckets.first(where: { $0.id == "3p-weekly" }))
        XCTAssertEqual(weekly.remainingPercent, 100)
    }

    func testBucketRemainingPercentIsClampedAndConservative() {
        func bucket(_ fraction: Double) -> GeminiUsageSnapshot.Bucket {
            .init(id: "b", name: "B", window: "weekly", remainingFraction: fraction)
        }
        XCTAssertEqual(bucket(0.996).remainingPercent, 99)
        XCTAssertEqual(bucket(0.004).remainingPercent, 0)
        // 0.29 * 100 == 28.999999999999996 in binary floating point; must still read 29.
        XCTAssertEqual(bucket(0.29).remainingPercent, 29)
        XCTAssertEqual(bucket(0.86).remainingPercent, 86)
        XCTAssertEqual(bucket(1.2).remainingPercent, 100)
        XCTAssertEqual(bucket(-0.1).remainingPercent, 0)
    }

    func testAgyErrorEnvelopeIsClassified() {
        // Shape observed from agy 1.5.8 when the signed-in account cannot use Antigravity (exit 1).
        let eligibility = Data(#"{"conversation_id":"","status":"ERROR","response":"","error":"Eligibility check failed: Your current account is not eligible for Antigravity. Verify your account to continue.","finished_reason":"error"}"#.utf8)
        XCTAssertEqual(GeminiUsageSnapshot.failure(stdout: eligibility, stderr: Data()), .loginRequired)

        let other = Data(#"{"status":"ERROR","error":"Internal server error"}"#.utf8)
        XCTAssertEqual(GeminiUsageSnapshot.failure(stdout: other, stderr: Data()), .requestFailed)

        // No envelope: fall back to stderr text, ignoring words that only appear inside URLs.
        XCTAssertEqual(GeminiUsageSnapshot.failure(stdout: Data(), stderr: Data("error: please sign in first".utf8)), .loginRequired)
        XCTAssertEqual(GeminiUsageSnapshot.failure(stdout: Data(), stderr: Data("error: boom https://example.com/auth_success".utf8)), .requestFailed)
    }

    func testUnparseableResetTimeIsNilNotNow() throws {
        let json = #"{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","name":"Weekly","window":"weekly","remaining_fraction":0.5,"reset_time":"not-a-date"}]}]}}}"#
        let snapshot = try GeminiUsageSnapshot.decode(from: Data(json.utf8))
        XCTAssertNil(snapshot.weeklyBucket?.resetTime)
    }

    func testNoGeminiGroupIsUnknownNotFull() throws {
        let json = #"{"command":{"data":{"groups":[{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","name":"Weekly","window":"weekly","remaining_fraction":1.0}]}]}}}"#
        let snapshot = try GeminiUsageSnapshot.decode(from: Data(json.utf8))
        XCTAssertNil(snapshot.primaryRemainingPercent)
        for mode in MenuBarDisplayMode.allCases {
            XCTAssertEqual(snapshot.formattedValue(for: mode), "?", "\(mode)")
        }
    }

    func testMalformedBucketInAnotherGroupDoesNotHideGeminiUsage() throws {
        let json = #"{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","name":"Weekly","window":"weekly","remaining_fraction":0.4}]},{"name":"Claude and GPT models","buckets":[{"id":"broken","name":"Broken"}]}]}}}"#
        let snapshot = try GeminiUsageSnapshot.decode(from: Data(json.utf8))
        XCTAssertEqual(snapshot.weeklyBucket?.remainingPercent, 40)
        // A group left with no readable buckets is dropped rather than shown as an empty heading.
        XCTAssertEqual(snapshot.groups.map(\.name), ["Gemini Models"])
    }

    func testBucketTitlesMatchTheOtherProviders() {
        func bucket(_ name: String, _ window: String) -> GeminiUsageSnapshot.Bucket {
            .init(id: "x", name: name, window: window, remainingFraction: 1)
        }
        XCTAssertEqual(bucket("Weekly Limit Remaining", "weekly").title, "Weekly Limit")
        XCTAssertEqual(bucket("Five Hour Limit Remaining", "5h").title, "5-Hour Limit")
        XCTAssertEqual(bucket("Daily Requests Remaining", "daily").title, "Daily Requests")
        XCTAssertEqual(bucket("Pro Session", "session").title, "Pro Session")
    }

    func testMalformedGroupDoesNotHideOtherGroups() throws {
        let json = #"{"command":{"data":{"groups":[{"buckets":"oops"},{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","name":"Weekly","window":"weekly","remaining_fraction":0.5}]}]}}}"#
        let snapshot = try GeminiUsageSnapshot.decode(from: Data(json.utf8))
        XCTAssertEqual(snapshot.weeklyBucket?.remainingPercent, 50)
    }

    func testEveryBucketUnreadableIsAnError() {
        let json = #"{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"x","name":"X","window":"weekly","fraction_left":0.5}]}]}}}"#
        XCTAssertThrowsError(try GeminiUsageSnapshot.decode(from: Data(json.utf8)))
    }
}
