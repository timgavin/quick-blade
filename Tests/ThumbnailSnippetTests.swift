import XCTest

final class ThumbnailSnippetTests: XCTestCase {

    func testTakesAtMostEighteenLines() {
        let source = (1...40).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ThumbnailProvider.snippetLines(from: source).count, 18)
    }

    func testTruncatesLongLines() {
        let long = String(repeating: "x", count: 200)
        let lines = ThumbnailProvider.snippetLines(from: long)
        XCTAssertEqual(lines.first?.count, 80)
    }

    func testExpandsTabsAndSkipsLeadingBlankLines() {
        let lines = ThumbnailProvider.snippetLines(from: "\n\n\t<div>\n")
        XCTAssertEqual(lines.first, "    <div>")
    }
}
