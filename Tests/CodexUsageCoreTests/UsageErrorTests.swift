import XCTest
@testable import CodexUsageCore

final class UsageErrorTests: XCTestCase {
    func testDefaultDescriptionsPreserveCodex() {
        XCTAssertEqual(UsageError.loginRequired.errorDescription, "Codex login required")
        XCTAssertEqual(UsageError.cliNotFound.errorDescription, "Codex CLI not found")
        XCTAssertEqual(UsageError.startFailed.errorDescription, "Unable to start Codex App Server")
        XCTAssertEqual(UsageError.connectionClosed.errorDescription, "Codex disconnected")
        XCTAssertEqual(UsageError.loginRequired.recoverySuggestion, "Run codex login in Terminal, then refresh.")
        XCTAssertEqual(UsageError.cliNotFound.recoverySuggestion, "Install the official Codex CLI or choose its executable in Settings.")
        XCTAssertEqual(UsageError.startFailed.recoverySuggestion, "Check the executable in Settings and confirm that codex runs in Terminal.")
        XCTAssertEqual(UsageError.unavailable.recoverySuggestion, "No Codex limit information was returned for this account.")
    }

    func testGeminiProviderDescriptionsAndSuggestions() {
        XCTAssertEqual(UsageError.loginRequired.errorDescription(for: "Gemini"), "Gemini login required")
        XCTAssertEqual(UsageError.cliNotFound.errorDescription(for: "Gemini"), "Gemini CLI not found")
        XCTAssertEqual(UsageError.startFailed.errorDescription(for: "Gemini"), "Unable to start Gemini CLI")
        XCTAssertEqual(UsageError.connectionClosed.errorDescription(for: "Gemini"), "Gemini disconnected")
        XCTAssertEqual(UsageError.unavailable.errorDescription(for: "Gemini"), "Usage unavailable")
        XCTAssertEqual(UsageError.requestFailed.errorDescription(for: "Gemini"), "Unable to retrieve usage")

        XCTAssertEqual(UsageError.loginRequired.recoverySuggestion(for: "Gemini"), "Sign in to your Google Antigravity account in Terminal, then refresh.")
        XCTAssertEqual(UsageError.cliNotFound.recoverySuggestion(for: "Gemini"), "Install the official Antigravity CLI (agy) or choose its executable in Settings.")
        XCTAssertEqual(UsageError.startFailed.recoverySuggestion(for: "Gemini"), "Check the executable in Settings and confirm that agy runs in Terminal.")
        XCTAssertEqual(UsageError.unavailable.recoverySuggestion(for: "Gemini"), "No Gemini limit information was returned for this account.")
        XCTAssertEqual(UsageError.requestFailed.recoverySuggestion(for: "Gemini"), "Check your connection. Usage will refresh automatically.")
    }
}
