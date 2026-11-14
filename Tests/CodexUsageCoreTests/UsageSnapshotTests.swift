import XCTest
@testable import CodexUsageCore

final class UsageSnapshotTests: XCTestCase {
    func decode(_ json: String) throws -> UsageSnapshot {
        try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    }

    func testRealWeeklyOnlyAccountDoesNotInventFiveHourQuota() throws {
        let data = try Data(contentsOf: Bundle.module.url(forResource: "response-redacted", withExtension: "json", subdirectory: "Fixtures")!)
        struct Envelope: Decodable { let result: UsageSnapshot }
        let snapshot = try JSONDecoder().decode(Envelope.self, from: data).result
        XCTAssertEqual(snapshot.menuBarTitle, "Codex 3%")
        XCTAssertEqual(snapshot.quotas.count, 1)
        XCTAssertEqual(snapshot.quotas[0].title, "Weekly Limit")
        XCTAssertEqual(snapshot.quotas[0].durationMinutes, 10080)
        XCTAssertEqual(snapshot.quotas[0].resetDate?.timeIntervalSince1970, 1789889786)
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 2)
    }

    func testOrdersWindowsByDurationInsteadOfPrimarySecondary() throws {
        let snapshot = try decode(#"{"rateLimits":{"primary":{"usedPercent":62,"windowDurationMins":10080},"secondary":{"usedPercent":26,"windowDurationMins":300}}}"#)
        XCTAssertEqual(snapshot.menuBarTitle, "Codex 74% / 38%")
        XCTAssertEqual(snapshot.quotas.map(\.title), ["5-Hour Limit", "Weekly Limit"])
    }

    func testCodexBucketTakesPrecedenceOverLegacyOtherBucket() throws {
        let snapshot = try decode(#"{"rateLimits":{"limitId":"other","primary":{"usedPercent":1}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":75,"windowDurationMins":300}}}}"#)
        XCTAssertEqual(snapshot.menuBarTitle, "Codex 25%")
    }

    func testOtherBucketsDoNotBecomeCodexUsage() throws {
        let snapshot = try decode(#"{"rateLimits":{"limitId":"other","primary":{"usedPercent":1}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":2}}}}"#)
        XCTAssertTrue(snapshot.quotas.isEmpty)
        XCTAssertEqual(snapshot.menuBarTitle, "Codex ?")
    }

    func testMissingAndUnknownPeriodsAreNotMislabelled() throws {
        let snapshot = try decode(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":null,"resetsAt":null},"secondary":{"usedPercent":10,"windowDurationMins":15}}}"#)
        XCTAssertEqual(snapshot.quotas.map(\.title), ["15-Minute Limit", "Usage Limit"])
        XCTAssertNil(snapshot.quotas.last?.resetDate)
        XCTAssertEqual(try decode(#"{"rateLimits":{"primary":null,"secondary":null}}"#).menuBarTitle, "Codex ?")
    }

    func testPercentagesAreClampedAndRoundedConservatively() throws {
        let snapshot = try decode(#"{"rateLimits":{"primary":{"usedPercent":101,"windowDurationMins":300},"secondary":{"usedPercent":-2,"windowDurationMins":10080}}}"#)
        XCTAssertEqual(snapshot.menuBarTitle, "Codex 0% / 100%")
        XCTAssertEqual(try decode(#"{"rateLimits":{"primary":{"usedPercent":25.1}}}"#).menuBarTitle, "Codex 74%")
    }

    func testMissingUsedPercentIsInvalidRatherThanZero() {
        XCTAssertThrowsError(try decode(#"{"rateLimits":{"primary":{"windowDurationMins":300}}}"#))
    }
}

final class QuotaLevelTests: XCTestCase {
    func testThresholds() {
        XCTAssertEqual(QuotaLevel(remainingPercent: 100), .normal)
        XCTAssertEqual(QuotaLevel(remainingPercent: 26), .normal)
        XCTAssertEqual(QuotaLevel(remainingPercent: 25), .low)
        XCTAssertEqual(QuotaLevel(remainingPercent: 11), .low)
        XCTAssertEqual(QuotaLevel(remainingPercent: 10), .critical)
        XCTAssertEqual(QuotaLevel(remainingPercent: 0), .critical)
    }

    func testRemainingPercentMath() {
        XCTAssertEqual(QuotaMath.remainingPercent(remaining: 74.9), 74)
        XCTAssertEqual(QuotaMath.remainingPercent(remaining: 28.999999999999996), 29)
        XCTAssertEqual(QuotaMath.remainingPercent(remaining: 150), 100)
        XCTAssertEqual(QuotaMath.remainingPercent(remaining: -5), 0)
        XCTAssertEqual(QuotaMath.remainingPercent(remaining: .nan), 0)
    }
}
