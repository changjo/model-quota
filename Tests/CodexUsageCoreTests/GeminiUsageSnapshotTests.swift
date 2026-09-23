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
}
