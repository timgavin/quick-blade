import XCTest

final class DiagnosticsStripTests: XCTestCase {

    private func diag(readDenied: Bool = false, layoutMissing: Bool = false)
        -> TemplateResolver.Diagnostics {
        let d = TemplateResolver.Diagnostics()
        d.readDenied = readDenied
        d.layoutMissing = layoutMissing
        return d
    }

    func testNoIssueNoMessage() {
        XCTAssertNil(DiagnosticsStrip.message(for: diag()))
    }

    func testReadDeniedMessage() {
        let m = DiagnosticsStrip.message(for: diag(readDenied: true))
        XCTAssertTrue(m?.contains("privacy protection") == true)
    }

    func testReadDeniedWinsOverLayoutMissing() {
        let m = DiagnosticsStrip.message(for: diag(readDenied: true, layoutMissing: true))
        XCTAssertTrue(m?.contains("privacy protection") == true)
    }

    func testLayoutMissingMessage() {
        let m = DiagnosticsStrip.message(for: diag(layoutMissing: true))
        XCTAssertTrue(m?.contains("layout") == true)
    }

    func testInjectBeforeClosingBody() {
        let html = "<html><body><p>Hi</p></body></html>"
        let out = DiagnosticsStrip.inject(into: html, message: "Test message")
        XCTAssertTrue(out.contains("Test message"))
        let stripIndex = out.range(of: "qb-diagnostics")!.lowerBound
        let bodyClose = out.range(of: "</body>")!.lowerBound
        XCTAssertLessThan(stripIndex, bodyClose)
    }

    func testInjectAppendsWhenNoBodyTag() {
        let out = DiagnosticsStrip.inject(into: "<p>Hi</p>", message: "Test message")
        XCTAssertTrue(out.contains("Test message"))
    }

    func testMessageIsHTMLEscaped() {
        let out = DiagnosticsStrip.inject(into: "<body></body>", message: "a < b & c")
        XCTAssertTrue(out.contains("a &lt; b &amp; c"))
    }
}
