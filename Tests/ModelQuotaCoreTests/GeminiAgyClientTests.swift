import XCTest
@testable import ModelQuotaCore

final class GeminiAgyClientTests: XCTestCase {
    @MainActor
    func testMockAgyClientReturnsSnapshot() async throws {
        let fixtureURL = Bundle.module.url(forResource: "agy-usage-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Tests/ModelQuotaCoreTests/Fixtures/agy-usage-sample.json")
        let data = try Data(contentsOf: fixtureURL)

        let client = MockGeminiAgyClient(mockData: data)
        let snapshot = try await client.readUsage()

        XCTAssertEqual(snapshot.primaryRemainingPercent, 86)
        XCTAssertEqual(snapshot.fiveHourRemainingPercent, 91)
    }

    @MainActor
    func testMockAgyClientThrowsOnEmptyOrError() async {
        let client = MockGeminiAgyClient(mockError: .startFailed)
        do {
            _ = try await client.readUsage()
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is UsageError)
        }
    }

    func testLocateAgyExecutableFindsStandardPaths() {
        // If agy is installed on the testing machine, it should resolve successfully
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/agy") {
            let path = GeminiAgyClient.locateAgy(customPath: "")
            XCTAssertEqual(path?.path, "/opt/homebrew/bin/agy")
        }
    }
}

@MainActor
final class MockGeminiAgyClient: GeminiUsageService {
    private let mockData: Data?
    private let mockError: UsageError?

    init(mockData: Data? = nil, mockError: UsageError? = nil) {
        self.mockData = mockData
        self.mockError = mockError
    }

    func readUsage() async throws -> GeminiUsageSnapshot {
        if let mockError { throw mockError }
        guard let mockData else { throw UsageError.unavailable }
        return try GeminiUsageSnapshot.decode(from: mockData)
    }
}
