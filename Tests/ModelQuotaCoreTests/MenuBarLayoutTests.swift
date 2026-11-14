import XCTest
@testable import ModelQuotaCore

final class MenuBarLayoutTests: XCTestCase {
    func testEmptyItemsReturnsEmptyColumns() {
        let columns = MenuBarLayout.organizeColumns(items: [])
        XCTAssertTrue(columns.isEmpty)
    }

    func testSingleItemReturnsOneColumnWithOneItem() {
        let item = ProviderUsageItem(id: "codex", label: "Codex", summaryValue: "97%")
        let columns = MenuBarLayout.organizeColumns(items: [item])
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns[0].count, 1)
        XCTAssertEqual(columns[0][0].id, "codex")
    }

    func testTwoItemsReturnsOneColumnWithTwoItems() {
        let item1 = ProviderUsageItem(id: "codex", label: "Codex", summaryValue: "97%")
        let item2 = ProviderUsageItem(id: "gemini", label: "Gemini", summaryValue: "86%")
        let columns = MenuBarLayout.organizeColumns(items: [item1, item2])
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns[0].count, 2)
        XCTAssertEqual(columns[0][0].id, "codex")
        XCTAssertEqual(columns[0][1].id, "gemini")
    }

    func testThreeItemsReturnsTwoColumnsWithMaxTwoRowsPerColumn() {
        let item1 = ProviderUsageItem(id: "codex", label: "Codex", summaryValue: "97%")
        let item2 = ProviderUsageItem(id: "gemini", label: "Gemini", summaryValue: "86%")
        let item3 = ProviderUsageItem(id: "claude", label: "Claude", summaryValue: "50%")
        let columns = MenuBarLayout.organizeColumns(items: [item1, item2, item3])
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].count, 2)
        XCTAssertEqual(columns[0][0].id, "codex")
        XCTAssertEqual(columns[0][1].id, "gemini")
        XCTAssertEqual(columns[1].count, 1)
        XCTAssertEqual(columns[1][0].id, "claude")
    }

    func testFourItemsReturnsTwoColumnsWithTwoRowsEach() {
        let item1 = ProviderUsageItem(id: "codex", label: "Codex", summaryValue: "97%")
        let item2 = ProviderUsageItem(id: "gemini", label: "Gemini", summaryValue: "86%")
        let item3 = ProviderUsageItem(id: "claude", label: "Claude", summaryValue: "50%")
        let item4 = ProviderUsageItem(id: "other", label: "Other", summaryValue: "100%")
        let columns = MenuBarLayout.organizeColumns(items: [item1, item2, item3, item4])
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].count, 2)
        XCTAssertEqual(columns[1].count, 2)
        XCTAssertEqual(columns[0][0].id, "codex")
        XCTAssertEqual(columns[0][1].id, "gemini")
        XCTAssertEqual(columns[1][0].id, "claude")
        XCTAssertEqual(columns[1][1].id, "other")
    }

    func testFiveItemsReturnsThreeColumns() {
        let items = (0..<5).map {
            ProviderUsageItem(id: "item\($0)", label: "Item\($0)", summaryValue: "\($0)%")
        }
        let columns = MenuBarLayout.organizeColumns(items: items)
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns[0].count, 2)
        XCTAssertEqual(columns[1].count, 2)
        XCTAssertEqual(columns[2].count, 1)
    }

    func testAccessibilityTextSaysRemainingAndNeverReadsSymbols() {
        XCTAssertEqual(ProviderUsageItem(id: "c", label: "Codex", summaryValue: "74% / 38%").accessibilityText,
                       "Codex: 74% / 38% remaining")
        XCTAssertEqual(ProviderUsageItem(id: "g", label: "Gemini", summaryValue: "?").accessibilityText, "Gemini: unavailable")
        XCTAssertEqual(ProviderUsageItem(id: "a", label: "Claude", summaryValue: "…").accessibilityText, "Claude: checking")
    }
}
