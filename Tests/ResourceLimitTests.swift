import XCTest

/// A previewed `.blade.php` is untrusted, so pathological-but-small input must not
/// be able to hang the Quick Look process or explode memory. These pin the bounds.
///
/// The timing assertions use deliberately loose budgets. Post-fix these run in
/// single-digit milliseconds; the bounds are set well above that so an ordinary
/// loaded machine won't flake, while still catching a return to super-linear
/// behaviour (the shapes below took seconds to minutes before the fixes).
final class ResourceLimitTests: XCTestCase {

    private func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    // MARK: - Unclosed <x-slot> (was O(n^3): 8KB took 4.2s, 16KB took 33s)

    /// The scan used to re-search the whole remaining document for every slot token.
    /// `<x-card>` deliberately does not exist on disk — the layout path used to run
    /// slot extraction before checking that, so a nonexistent component was enough.
    func testUnclosedSlotsDoNotHang() throws {
        let project = try FixtureProject()
        let payload = String(repeating: "<x-slot:a>yyyyyyyyyy", count: 800)
        let page = "<x-card>" + payload + "</x-card>"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let seconds = elapsed { _ = TemplateResolver.resolve(source: page, fileURL: pageURL) }
        XCTAssertLessThan(seconds, 2.0,
                          "unclosed <x-slot> scan is super-linear again (\(seconds)s for \(page.utf8.count) bytes)")
    }

    func testUnclosedNameAttributeSlotsDoNotHang() throws {
        let project = try FixtureProject()
        let payload = String(repeating: "<x-slot name=\"a\">yyyy", count: 800)
        let page = "<x-card>" + payload + "</x-card>"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let seconds = elapsed { _ = TemplateResolver.resolve(source: page, fileURL: pageURL) }
        XCTAssertLessThan(seconds, 2.0,
                          "unclosed <x-slot name=…> scan is super-linear again (\(seconds)s)")
    }

    /// Scaling check, comparing ratios rather than absolute times so it doesn't
    /// depend on machine speed.
    ///
    /// The threshold used to be 6.0, chosen to catch the cubic growth (~8x per
    /// doubling) this shape started with. That could not tell quadratic (~4x) from
    /// linear (~2x), so it kept passing while a second, separate quadratic scan
    /// survived in `resolveComponents` — see `testUnmatchedComponentTagsDoNotHang`.
    /// 3.5 sits between linear and quadratic, matching the echo test below.
    func testUnclosedSlotCostGrowsRoughlyLinearly() throws {
        func cost(_ n: Int) throws -> TimeInterval {
            let project = try FixtureProject()
            let page = "<x-card>" + String(repeating: "<x-slot:a>yyyyyyyyyy", count: n) + "</x-card>"
            let pageURL = try project.write("resources/views/pages/test.blade.php", page)
            return elapsed { _ = TemplateResolver.resolve(source: page, fileURL: pageURL) }
        }
        _ = try cost(200)                       // warm caches, ignore
        let small = try cost(400)
        let large = try cost(800)
        // Floor the denominator so a sub-millisecond `small` can't blow up the ratio.
        let ratio = large / max(small, 0.001)
        XCTAssertLessThan(ratio, 3.5,
                          "doubling the input multiplied cost by \(ratio)x — expected ~2x, quadratic would be ~4x")
    }

    // MARK: - Unmatched <x-…> open tags
    //
    // Separate from the slot scan above. `resolveComponents` looks for the matching
    // `</x-name>` by searching from each open tag to end-of-document, so N open tags
    // with no closing tag cost N full-tail scans. Well-formed pairs are unaffected —
    // their search stops at the nearby close — so this only bites on malformed input,
    // which is exactly what a hostile file supplies.

    func testUnmatchedComponentTagsDoNotHang() throws {
        let project = try FixtureProject()
        // The component deliberately does not exist: nothing should be scanned for
        // a component that can't be resolved in the first place.
        let page = String(repeating: "<x-nosuch> filler filler\n", count: 5000)
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let seconds = elapsed { _ = TemplateResolver.resolve(source: page, fileURL: pageURL) }
        XCTAssertLessThan(seconds, 2.0,
                          "unmatched <x-…> tag scan is super-linear (\(seconds)s for \(page.utf8.count) bytes)")
    }

    /// Quadrupling the input should roughly quadruple the work. Quadratic would be
    /// ~16x. The threshold sits between the two so it cannot be satisfied by either
    /// neighbour by accident.
    func testUnmatchedComponentCostGrowsRoughlyLinearly() throws {
        func cost(_ n: Int) throws -> TimeInterval {
            let project = try FixtureProject()
            let page = String(repeating: "<x-nosuch> filler filler\n", count: n)
            let pageURL = try project.write("resources/views/pages/test.blade.php", page)
            return elapsed { _ = TemplateResolver.resolve(source: page, fileURL: pageURL) }
        }
        _ = try cost(400)                       // warm caches, ignore
        let small = try cost(750)
        let large = try cost(3000)
        let ratio = large / max(small, 0.001)
        XCTAssertLessThan(ratio, 8.0,
                          "quadrupling the input multiplied cost by \(ratio)x — expected ~4x, quadratic would be ~16x")
    }

    /// The same shape naming a component that DOES resolve, so the existence check
    /// can't short-circuit it. `resolveComponentToFile` falls back to plain view
    /// names, and stock Laravel ships `resources/views/welcome.blade.php` — so this
    /// is reachable with a hostile file alone, not just a hostile project.
    func testUnmatchedResolvableComponentTagsDoNotHang() throws {
        let project = try FixtureProject()
        try project.write("resources/views/welcome.blade.php", "<h1>Welcome</h1>")
        let page = String(repeating: "<x-welcome> filler filler\n", count: 5000)
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let seconds = elapsed { _ = TemplateResolver.resolve(source: page, fileURL: pageURL) }
        XCTAssertLessThan(seconds, 2.0,
                          "unmatched resolvable <x-…> tags are super-linear (\(seconds)s for \(page.utf8.count) bytes)")
    }

    func testUnmatchedResolvableComponentCostGrowsRoughlyLinearly() throws {
        func cost(_ n: Int) throws -> TimeInterval {
            let project = try FixtureProject()
            try project.write("resources/views/welcome.blade.php", "<h1>Welcome</h1>")
            let page = String(repeating: "<x-welcome> filler filler\n", count: n)
            let pageURL = try project.write("resources/views/pages/test.blade.php", page)
            return elapsed { _ = TemplateResolver.resolve(source: page, fileURL: pageURL) }
        }
        _ = try cost(400)                       // warm caches, ignore
        let small = try cost(750)
        let large = try cost(3000)
        let ratio = large / max(small, 0.001)
        XCTAssertLessThan(ratio, 8.0,
                          "quadrupling the input multiplied cost by \(ratio)x — expected ~4x, quadratic would be ~16x")
    }

    /// The bound counts FAILED pair searches, not components. A page with far more
    /// well-formed components than the cap must still resolve every one of them —
    /// otherwise the fix would quietly stop rendering large real pages.
    func testManyWellFormedComponentsAllStillResolve() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/row.blade.php", "<li>{{ $slot }}</li>")
        let count = 500                          // well above the failed-scan cap
        var page = ""
        for i in 0..<count { page += "<x-row>item\(i)</x-row>\n" }
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let html = TemplateResolver.resolve(source: page, fileURL: pageURL).html
        XCTAssertTrue(html.contains("<li>item0</li>"), "first component did not resolve")
        XCTAssertTrue(html.contains("<li>item499</li>"), "last component did not resolve")
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, count,
                       "not every well-formed component resolved")
    }

    /// Well-formed component pairs must keep resolving — the cheap path added for
    /// the case above must not skip components that really are there.
    func testMatchedComponentPairsStillResolve() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/foo.blade.php", "<b>{{ $slot }}</b>")
        let page = "<x-foo>hello</x-foo>"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let html = TemplateResolver.resolve(source: page, fileURL: pageURL).html
        XCTAssertTrue(html.contains("<b>hello</b>"),
                      "matched component pair no longer resolves: \(html)")
    }

    // MARK: - Recursive @include (was 16 bytes -> 16.8MB)

    func testSelfReferencingIncludeIsBounded() throws {
        let project = try FixtureProject()
        try project.write("resources/views/bomb.blade.php",
                          "PAYLOAD" + String(repeating: "@include('bomb')", count: 16))
        let page = "@include('bomb')"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        var html = ""
        let seconds = elapsed { html = TemplateResolver.resolve(source: page, fileURL: pageURL).html }
        XCTAssertLessThan(html.utf8.count, 4 * 1024 * 1024,
                          "include expansion produced \(html.utf8.count) bytes from a \(page.utf8.count)-byte file")
        XCTAssertLessThan(seconds, 5.0, "include expansion took \(seconds)s")
    }

    func testMutuallyRecursiveIncludesAreBounded() throws {
        let project = try FixtureProject()
        try project.write("resources/views/ping.blade.php",
                          "PING" + String(repeating: "@include('pong')", count: 8))
        try project.write("resources/views/pong.blade.php",
                          "PONG" + String(repeating: "@include('ping')", count: 8))
        let page = "@include('ping')"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        var html = ""
        let seconds = elapsed { html = TemplateResolver.resolve(source: page, fileURL: pageURL).html }
        XCTAssertLessThan(html.utf8.count, 4 * 1024 * 1024,
                          "mutually recursive includes produced \(html.utf8.count) bytes")
        XCTAssertLessThan(seconds, 5.0, "mutually recursive includes took \(seconds)s")
    }

    // MARK: - Recursive components (was 220 bytes -> 27.9MB in 22.7s at fan-out 50)

    func testSelfReferencingComponentIsBounded() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/cbomb.blade.php",
                          "PAYLOAD" + String(repeating: "<x-cbomb />", count: 50))
        let page = String(repeating: "<x-cbomb />", count: 20)
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        var html = ""
        let seconds = elapsed { html = TemplateResolver.resolve(source: page, fileURL: pageURL).html }
        XCTAssertLessThan(html.utf8.count, 4 * 1024 * 1024,
                          "component expansion produced \(html.utf8.count) bytes from \(page.utf8.count)")
        XCTAssertLessThan(seconds, 5.0, "component expansion took \(seconds)s")
    }

    /// Ordinary nested components must still resolve — the cap is a ceiling, not a ban.
    func testOrdinaryNestedComponentsStillResolve() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/inner.blade.php", "INNER")
        try project.write("resources/views/components/outer.blade.php", "OUTER <x-inner />")
        let page = "<x-outer />"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let html = TemplateResolver.resolve(source: page, fileURL: pageURL).html
        XCTAssertTrue(html.contains("OUTER"), "outer component did not inline")
        XCTAssertTrue(html.contains("INNER"), "nested component did not inline")
    }

    /// Ordinary nested includes must still resolve — the cap is a ceiling, not a ban.
    func testOrdinaryNestedIncludesStillResolve() throws {
        let project = try FixtureProject()
        try project.write("resources/views/partials/inner.blade.php", "INNER")
        try project.write("resources/views/partials/outer.blade.php", "OUTER @include('partials.inner')")
        let page = "@include('partials.outer')"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let html = TemplateResolver.resolve(source: page, fileURL: pageURL).html
        XCTAssertTrue(html.contains("OUTER"), "outer partial did not inline")
        XCTAssertTrue(html.contains("INNER"), "nested partial did not inline")
    }

    // MARK: - Unterminated quote in a component tag (was O(n^2))

    /// Covers the WHOLE pipeline, not just the resolver. An earlier version of this
    /// test only called `resolve` and reported the fix as complete while the same
    /// input still cost 20s inside the transpiler's own tag-stripping passes.
    func testUnterminatedQuoteInComponentTagDoesNotHang() throws {
        let project = try FixtureProject()
        let page = String(repeating: "<x-a ", count: 3000) + "\"" + String(repeating: "x", count: 300_000)
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let seconds = elapsed {
            let resolved = TemplateResolver.resolve(source: page, fileURL: pageURL)
            _ = BladeTranspiler.transpile(resolved.html)
        }
        XCTAssertLessThan(seconds, 5.0,
                          "unterminated quote backtracking is super-linear again (\(seconds)s)")
    }

    /// The same shape with echoes present, which additionally engages the tag scan in
    /// placeholder classification.
    func testUnterminatedQuoteWithEchoesDoesNotHang() throws {
        let project = try FixtureProject()
        let page = "{{ $a }}" + String(repeating: "<x-a ", count: 3000)
            + "\"" + String(repeating: "x", count: 300_000)
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let seconds = elapsed {
            let resolved = TemplateResolver.resolve(source: page, fileURL: pageURL)
            _ = BladeTranspiler.transpile(resolved.html)
        }
        XCTAssertLessThan(seconds, 5.0,
                          "unterminated quote with echoes is super-linear (\(seconds)s)")
    }

    // MARK: - Many echoes (was O(n^2): 254KB of ordinary markup took 18.4s)

    func testManyEchoesTranspileInReasonableTime() {
        var source = ""
        for i in 0..<8000 { source += "<p>hello {{ $a\(i) }} world</p>\n" }

        let seconds = elapsed { _ = BladeTranspiler.transpile(source) }
        XCTAssertLessThan(seconds, 3.0,
                          "transpile is quadratic in echo count again (\(seconds)s for \(source.utf8.count) bytes)")
    }

    func testManyDynamicImageSourcesTranspileInReasonableTime() {
        var source = ""
        for i in 0..<2000 { source += "<img src=\"{{ $u\(i) }}\">\n" }

        let seconds = elapsed { _ = BladeTranspiler.transpile(source) }
        XCTAssertLessThan(seconds, 3.0,
                          "dynamic img src replacement is quadratic again (\(seconds)s)")
    }

    /// Doubling echo count should roughly double the work, not quadruple it.
    func testTranspileCostGrowsRoughlyLinearlyWithEchoes() {
        func cost(_ n: Int) -> TimeInterval {
            var source = ""
            for i in 0..<n { source += "<p>hello {{ $a\(i) }} world</p>\n" }
            return elapsed { _ = BladeTranspiler.transpile(source) }
        }
        _ = cost(1000)                          // warm caches, ignore
        let small = cost(2000)
        let large = cost(4000)
        let ratio = large / max(small, 0.001)
        XCTAssertLessThan(ratio, 3.5,
                          "doubling echoes multiplied cost by \(ratio)x — expected ~2x, quadratic would be ~4x")
    }
}
