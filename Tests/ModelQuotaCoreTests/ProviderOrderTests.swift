import XCTest
@testable import ModelQuotaCore

final class ProviderOrderTests: XCTestCase {
    func testDefaultOrderIsCodexGeminiClaude() {
        XCTAssertEqual(ProviderOrder.default, [.codex, .gemini, .claude])
    }

    func testNormalizedKeepsACompleteOrder() {
        XCTAssertEqual(ProviderOrder.normalized([.claude, .codex, .gemini]), [.claude, .codex, .gemini])
    }

    func testNormalizedDropsDuplicatesAndAppendsMissingKindsInDefaultOrder() {
        XCTAssertEqual(ProviderOrder.normalized([.claude, .claude]), [.claude, .codex, .gemini])
        XCTAssertEqual(ProviderOrder.normalized([.gemini, .codex, .gemini, .codex]), [.gemini, .codex, .claude])
        XCTAssertEqual(ProviderOrder.normalized([]), [.codex, .gemini, .claude])
    }

    func testNormalizedRawValuesDropsUnknownEntries() {
        XCTAssertEqual(ProviderOrder.normalized(rawValues: ["claude", "openai", "", "Gemini", "gemini", "claude"]),
                       [.claude, .gemini, .codex])
        XCTAssertEqual(ProviderOrder.normalized(rawValues: []), [.codex, .gemini, .claude])
    }

    func testMoveShiftsOneStepUpOrDown() {
        let order: [ProviderKind] = [.codex, .gemini, .claude]
        XCTAssertEqual(ProviderOrder.move(.gemini, by: -1, in: order), [.gemini, .codex, .claude])
        XCTAssertEqual(ProviderOrder.move(.gemini, by: 1, in: order), [.codex, .claude, .gemini])
        XCTAssertEqual(ProviderOrder.move(.claude, by: -2, in: order), [.claude, .codex, .gemini])
    }

    func testMovePastEitherEndIsClamped() {
        let order: [ProviderKind] = [.claude, .codex, .gemini]
        XCTAssertEqual(ProviderOrder.move(.claude, by: -1, in: order), order)
        XCTAssertEqual(ProviderOrder.move(.gemini, by: 1, in: order), order)
        XCTAssertEqual(ProviderOrder.move(.codex, by: 5, in: order), [.claude, .gemini, .codex])
    }

    func testMoveNormalizesAnIncompleteOrder() {
        XCTAssertEqual(ProviderOrder.move(.claude, by: -1, in: [.gemini, .gemini]), [.gemini, .claude, .codex])
    }
}
