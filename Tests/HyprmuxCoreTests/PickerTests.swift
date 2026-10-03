import XCTest
@testable import HyprmuxCore

final class FuzzyMatchTests: XCTestCase {
    func testSubsequenceRequired() {
        XCTAssertNotNil(FuzzyMatch.match("ipn", in: "iPhone 16 Pro"))
        XCTAssertNil(FuzzyMatch.match("xyz", in: "iPhone 16 Pro"))
        XCTAssertNil(FuzzyMatch.match("pi", in: "ip"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.match("", in: "anything"), FuzzyMatch.Result(score: 0, positions: []))
        XCTAssertEqual(FuzzyMatch.match("   ", in: "anything")?.positions, [])
    }

    func testSmartCase() {
        XCTAssertNotNil(FuzzyMatch.match("pro", in: "iPhone Pro"))
        XCTAssertNil(FuzzyMatch.match("PRO", in: "iPhone Pro"))
        XCTAssertNotNil(FuzzyMatch.match("Pro", in: "iPhone Pro"))
    }

    func testPrefersWordStartsAndRuns() {
        // "pro" at the word start beats p…r…o scattered earlier.
        let m = FuzzyMatch.match("pro", in: "iphone prime Pro")!
        XCTAssertEqual(m.positions, [13, 14, 15])
        // A consecutive run scores higher than the same letters spread out.
        let run = FuzzyMatch.match("term", in: "terminal")!.score
        let spread = FuzzyMatch.match("term", in: "the everyday rum")!.score
        XCTAssertGreaterThan(run, spread)
    }

    func testTermsMatchIndependently() {
        let m = FuzzyMatch.match("27 max", in: "iPhone 17 Pro Max iOS 27.0")
        XCTAssertNotNil(m)
        XCTAssertNil(FuzzyMatch.match("27 mini", in: "iPhone 17 Pro Max iOS 27.0"))
    }

    func testCamelCaseBoundary() {
        XCTAssertTrue(FuzzyMatch.isBoundary(Array("fooBar"), 3))
        XCTAssertFalse(FuzzyMatch.isBoundary(Array("foobar"), 3))
        XCTAssertTrue(FuzzyMatch.isBoundary(Array("foo-bar"), 4))
    }
}

final class PickerTests: XCTestCase {
    let items = [
        PickerItem(id: "a", title: "iPhone 17 Pro", detail: "iOS 27.0"),
        PickerItem(id: "b", title: "iPad Air", detail: "iOS 26.5"),
        PickerItem(id: "c", title: "Demo App", detail: "iOS 27.0"),
    ]

    func testEmptyQueryListsEverythingInOrder() {
        let p = Picker(title: "sim", items: items)
        XCTAssertEqual(p.rows.map(\.index), [0, 1, 2])
        XCTAssertEqual(p.selection, 0)
        XCTAssertEqual(p.result, .item("a"))
    }

    func testRowLayoutDefaultsToInlineAndStackedStillSearchesBothLines() {
        let inline = Picker(title: "default", items: items)
        var stacked = Picker(title: "credentials", items: items, rowLayout: .stacked)

        XCTAssertEqual(inline.rowLayout, .inline)
        XCTAssertEqual(stacked.rowLayout, .stacked)
        XCTAssertEqual(stacked.visibleRows.count, inline.visibleRows.count)
        XCTAssertEqual(stacked.result, inline.result)

        stacked.setQuery("iPad 26.5")
        XCTAssertEqual(stacked.result, .item("b"))
        XCTAssertFalse(stacked.rows[0].titleMatches.isEmpty)
        XCTAssertFalse(stacked.rows[0].detailMatches.isEmpty)
    }

    func testFilterRanksAndSplitsHighlights() {
        var p = Picker(title: "sim", items: items)
        p.setQuery("pad")
        XCTAssertEqual(p.rows.map(\.index), [1])
        XCTAssertEqual(p.rows[0].titleMatches, [1, 2, 3])
        p.setQuery("26")
        XCTAssertEqual(p.rows.map(\.index), [1])
        XCTAssertEqual(p.rows[0].titleMatches, [])
        XCTAssertEqual(p.rows[0].detailMatches, [4, 5])
        p.setQuery("zzz")
        XCTAssertTrue(p.rows.isEmpty)
        XCTAssertNil(p.selection)
        XCTAssertNil(p.result)
    }

    func testCustomTextWhenNothingMatches() {
        var p = Picker(title: "workspace", items: items, allowsCustom: true)
        p.setQuery("  mail  ")
        XCTAssertEqual(p.result, .text("mail"))
        p.setQuery("")
        XCTAssertEqual(p.result, .item("a"))
    }

    func testPromptReturnsText() {
        var p = Picker(title: "name", mode: .prompt, query: "old")
        XCTAssertTrue(p.rows.isEmpty)
        XCTAssertEqual(p.result, .text("old"))
        p.setQuery("")
        XCTAssertEqual(p.result, .text(""))
    }

    func testMoveWrapsAndScrolls() {
        let many = (0..<25).map { PickerItem(id: "\($0)", title: "item \($0)") }
        var p = Picker(title: "x", items: many, maxVisible: 10)
        p.move(-1)
        XCTAssertEqual(p.selection, 24)
        XCTAssertEqual(p.scroll, 15)
        XCTAssertEqual(p.visibleRows.count, 10)
        p.move(1)
        XCTAssertEqual(p.selection, 0)
        XCTAssertEqual(p.scroll, 0)
        p.page(1)
        XCTAssertEqual(p.selection, 10)
        XCTAssertEqual(p.scroll, 1)
        p.page(1); p.page(1)
        XCTAssertEqual(p.selection, 24)
        p.page(-1)
        XCTAssertEqual(p.selection, 14)
        XCTAssertEqual(p.scroll, 14)
    }

    func testQueryResetsSelection() {
        var p = Picker(title: "x", items: items)
        p.move(2)
        p.setQuery("i")
        XCTAssertEqual(p.selection, 0)
        XCTAssertEqual(p.scroll, 0)
    }

    func testSetItemsPreservesQueryAndSelectionByIDWhenRowsReorder() {
        let original = [
            PickerItem(id: "a", title: "Alpha One"),
            PickerItem(id: "b", title: "Alpha Two"),
        ]
        var p = Picker(title: "x", items: original, query: "alpha")
        p.move(1)
        XCTAssertEqual(p.selectedItem?.id, "b")

        let reordered = [PickerItem(id: "c", title: "Alpha New"), original[1], original[0]]
        p.setItems(reordered)

        XCTAssertEqual(p.query, "alpha")
        XCTAssertEqual(p.rows.map { p.items[$0.index].id }, ["c", "b", "a"])
        XCTAssertEqual(p.selectedItem?.id, "b")
    }

    func testStatusCanBeSetAndCleared() {
        var p = Picker(title: "x", status: "loading Vault…")
        XCTAssertEqual(p.status, "loading Vault…")
        p.status = nil
        XCTAssertNil(p.status)
    }
}
