import XCTest
@testable import CodexUsageCore

final class ClaudeClientTests: XCTestCase {
    @MainActor
    func testMockClaudeClientReturnsSnapshot() async throws {
        let streamJson = """
        {"type":"control_response","response":{"subtype":"success","response":{"subscription_type":"Claude Pro","rate_limits_available":true,"rate_limits":{"five_hour":{"resets_at":"2026-10-15T11:00:00.000Z","utilization":30.0},"seven_day":{"resets_at":"2026-10-21T06:00:00.000Z","utilization":60.0},"seven_day_breakdown":{"rows":[{"display_name":"Claude 3.7 Sonnet","key":"claude-3-7-sonnet","percent":55.0}]}}}}}
        """
        let client = MockClaudeClient(mockData: Data(streamJson.utf8))
        let snapshot = try await client.readUsage()

        XCTAssertEqual(snapshot.subscriptionType, "Claude Pro")
        XCTAssertEqual(snapshot.primaryRemainingPercent, 40)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 70)
        XCTAssertEqual(snapshot.breakdownRows.count, 1)
    }

    @MainActor
    func testMockClaudeClientThrowsOnError() async {
        let client = MockClaudeClient(mockError: .loginRequired)
        do {
            _ = try await client.readUsage()
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(error as? UsageError, .loginRequired)
        }
    }

    func testLocateClaudeExecutable() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let localClaude = (homeDir as NSString).appendingPathComponent(".local/bin/claude")
        if FileManager.default.isExecutableFile(atPath: localClaude) {
            let located = ClaudeClient.locateClaude()
            XCTAssertNotNil(located)
            XCTAssertEqual(located?.path, localClaude)
        }
    }

    func testLocateClaudeCustomPath() {
        let invalid = ClaudeClient.locateClaude(customPath: "/nonexistent/path/to/claude")
        // If system has claude in standard paths, customPath override might fallback or fail
        // Testing that a valid executable path works
        let bash = "/bin/bash"
        if FileManager.default.isExecutableFile(atPath: bash) {
            let located = ClaudeClient.locateClaude(customPath: bash)
            XCTAssertEqual(located?.path, bash)
        }
    }
}

@MainActor
final class MockClaudeClient: ClaudeUsageService {
    private let mockData: Data?
    private let mockError: UsageError?

    init(mockData: Data? = nil, mockError: UsageError? = nil) {
        self.mockData = mockData
        self.mockError = mockError
    }

    func readUsage() async throws -> ClaudeUsageSnapshot {
        if let mockError { throw mockError }
        guard let mockData else { throw UsageError.unavailable }
        return try ClaudeUsageSnapshot.decode(from: mockData)
    }
}
