import XCTest

/// The extension previews untrusted `.blade.php` files while holding read-only
/// access to the whole home folder, so every path built from template text must
/// stay inside the directory it is resolved against. These tests plant a canary
/// outside the project and assert it never reaches the rendered preview.
///
/// Fixture note, learned the hard way: POSIX resolves `..` component by
/// component, so `public/../../x` only escapes if `public/` actually exists on
/// disk. A fixture without a real `public/` tree makes every traversal test
/// pass for the wrong reason. `makeProject` always builds one.
final class PathTraversalTests: XCTestCase {

    private static let canary = "CANARY-OUTSIDE-THE-PROJECT-0123456789"
    private static var canaryBase64: String { Data(canary.utf8).base64EncodedString() }

    /// A project with a realistic `public/` tree and a canary planted outside it.
    private func makeProject(canaryExt: String = "png") throws -> FixtureProject {
        let project = try FixtureProject()
        try project.writeOutside("canary.\(canaryExt)", Self.canary)
        // Real directories, so `..` has something to climb through.
        try project.write("public/index.php", "<?php")
        try project.write("public/img/logo.png", "REAL-PROJECT-IMAGE")
        try project.write("public/css/site.css", "/* */")
        return project
    }

    private func render(_ project: FixtureProject, _ page: String) throws -> String {
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        return TemplateResolver.resolve(source: page, fileURL: pageURL).html
    }

    private func assertNoLeak(
        _ html: String, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(html.contains(Self.canaryBase64),
                       "\(what) — file outside the project was inlined", file: file, line: line)
        XCTAssertFalse(html.contains(Self.canary),
                       "\(what) — file outside the project leaked verbatim", file: file, line: line)
    }

    private func assertInlined(
        _ html: String, _ contents: String, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(html.contains("base64,\(Data(contents.utf8).base64EncodedString())"),
                      "containment broke \(what)", file: file, line: line)
    }

    /// Guards the guard: proves the fixture can actually reach outside the project,
    /// so the traversal tests below fail loudly if containment regresses rather than
    /// passing because the path never resolved.
    func testFixtureCanReachOutsideProject() throws {
        let project = try makeProject()
        let escaped = project.root
            .appendingPathComponent("public")
            .appendingPathComponent("../../\(project.outsideName)/canary.png")
        XCTAssertEqual(try String(contentsOf: escaped, encoding: .utf8), Self.canary,
                       "fixture cannot escape the project — traversal tests would pass vacuously")
    }

    // MARK: - <img src> (reachable with a hostile .blade.php alone)

    func testImgSrcCannotClimbOutOfPublic() throws {
        let p = try makeProject()
        assertNoLeak(try render(p, #"<img src="/../../\#(p.outsideName)/canary.png">"#),
                     "root-relative ../ traversal")
    }

    func testImgSrcRelativeTraversalIsBlocked() throws {
        let p = try makeProject()
        assertNoLeak(try render(p, #"<img src="../../\#(p.outsideName)/canary.png">"#),
                     "relative ../ traversal")
    }

    func testImgSrcMixedDotSegmentsAreBlocked() throws {
        let p = try makeProject()
        assertNoLeak(try render(p, #"<img src="/./.././../\#(p.outsideName)/canary.png">"#),
                     "mixed ./ and ../ segments")
    }

    func testImgSrcSingleQuotedTraversalIsBlocked() throws {
        let p = try makeProject()
        assertNoLeak(try render(p, "<img src='/../../\(p.outsideName)/canary.png'>"),
                     "single-quoted src")
    }

    /// `.svg` is a text format, so a traversal landing on one leaks the file's full
    /// text rather than an opaque blob. Worth pinning separately.
    func testImgSrcTraversalToSVGIsBlocked() throws {
        let p = try makeProject(canaryExt: "svg")
        assertNoLeak(try render(p, #"<img src="/../../\#(p.outsideName)/canary.svg">"#),
                     "traversal to a text-format .svg")
    }

    /// `{{ asset() }}` / `{{ url() }}` are rewritten to root-relative paths before
    /// image inlining, so they reach the same sink and need the same containment.
    func testAssetEchoTraversalIsBlocked() throws {
        let p = try makeProject()
        assertNoLeak(try render(p, #"<img src="{{ asset('../../\#(p.outsideName)/canary.png') }}">"#),
                     "asset() traversal")
    }

    func testUrlEchoTraversalIsBlocked() throws {
        let p = try makeProject()
        assertNoLeak(try render(p, #"<img src="{{ url('../../\#(p.outsideName)/canary.png') }}">"#),
                     "url() traversal")
    }

    // MARK: - CSS url() (reachable when the attacker also supplies the project)

    func testCSSUrlTraversalIsBlocked() throws {
        let p = try makeProject()
        try p.write("public/build/assets/app.css",
                    "body{background:url(/../../\(p.outsideName)/canary.png)}")
        assertNoLeak(try render(p, "<p>hi</p>"), "CSS url() traversal")
    }

    /// `inlineFontURLs` resolves relative to the stylesheet's own directory and
    /// standardizes the URL, which collapses `..` by design — so it needs an
    /// explicit containment check.
    func testFontAwesomeWebfontTraversalIsBlocked() throws {
        let p = try makeProject(canaryExt: "woff2")
        try p.write("public/fonts/css/all.min.css",
                    "@font-face{src:url(../../../../\(p.outsideName)/canary.woff2)}")
        assertNoLeak(try render(p, #"<i class="fa-solid fa-user"></i>"#),
                     "FontAwesome webfont traversal")
    }

    // MARK: - Positive controls: legitimate in-project assets must still inline

    func testLegitimateProjectImageStillInlines() throws {
        let p = try makeProject()
        assertInlined(try render(p, #"<img src="/img/logo.png">"#),
                      "REAL-PROJECT-IMAGE", "ordinary in-project image inlining")
    }

    func testLegitimateNestedProjectImageStillInlines() throws {
        let p = try makeProject()
        try p.write("public/img/deep/nested/logo.png", "NESTED-IMAGE")
        assertInlined(try render(p, #"<img src="/img/deep/nested/logo.png">"#),
                      "NESTED-IMAGE", "nested in-project image inlining")
    }

    /// A `..` that stays inside public/ is harmless. Pinned so nobody "fixes" the
    /// traversal by rejecting every src containing "..".
    func testInnocentDotSegmentInsidePublicStillInlines() throws {
        let p = try makeProject()
        assertInlined(try render(p, #"<img src="/css/../img/logo.png">"#),
                      "REAL-PROJECT-IMAGE", "a ../ that stays inside public/")
    }

    func testLegitimateCSSUrlStillInlines() throws {
        let p = try makeProject()
        try p.write("public/build/assets/app.css", "body{background:url(/img/bg.png)}")
        try p.write("public/img/bg.png", "CSS-BG-IMAGE")
        assertInlined(try render(p, "<p>hi</p>"), "CSS-BG-IMAGE", "ordinary CSS url() inlining")
    }

    // MARK: - Attribute escaping

    /// A prop containing an apostrophe used to close a single-quoted attribute early,
    /// so the rest of the value became markup instead of text.
    func testApostropheInPropDoesNotEscapeSingleQuotedAttribute() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/card.blade.php",
                          "<div title='{{ $title }}'>body</div>")
        let page = #"<x-card title="Tim's card" />"#
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let html = TemplateResolver.resolve(source: page, fileURL: pageURL).html
        XCTAssertTrue(html.contains("title='Tim&#39;s card'"),
                      "apostrophe was not escaped inside a single-quoted attribute")
        XCTAssertFalse(html.contains("title='Tim's"),
                       "apostrophe closed the attribute early")
    }

    func testApostropheSurvivesInBodyText() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/card.blade.php", "<p>{{ $title }}</p>")
        let page = #"<x-card title="Tim's card" />"#
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)

        let html = TemplateResolver.resolve(source: page, fileURL: pageURL).html
        XCTAssertTrue(html.contains("Tim&#39;s card"), "apostrophe lost from body text")
    }

    // MARK: - Symlinks
    //
    // Containment resolves symlinks, which is what stops a link planted inside
    // `public/` from pointing at the rest of the home folder. But Laravel itself
    // ships a symlink that legitimately leaves `public/`: `artisan storage:link`
    // creates `public/storage -> ../storage/app/public`, and every app that
    // serves user uploads references it as `/storage/…`.

    /// The `artisan storage:link` layout. Leaves `public/` but stays in the project.
    func testStorageSymlinkedImageStillInlines() throws {
        let p = try makeProject()
        try p.write("storage/app/public/avatar.png", "STORAGE-UPLOAD-IMAGE")
        try p.symlink("public/storage", to: "../storage/app/public")

        assertInlined(try render(p, #"<img src="/storage/avatar.png">"#),
                      "STORAGE-UPLOAD-IMAGE", "Laravel's public/storage symlink")
    }

    /// The same shape in CSS, which resolves through the same containment helper.
    func testStorageSymlinkedCSSResourceStillInlines() throws {
        let p = try makeProject()
        try p.write("storage/app/public/hero.png", "STORAGE-CSS-IMAGE")
        try p.symlink("public/storage", to: "../storage/app/public")
        try p.write("public/build/assets/app.css", "body{background:url(/storage/hero.png)}")

        assertInlined(try render(p, "<p>hi</p>"),
                      "STORAGE-CSS-IMAGE", "public/storage symlink from CSS")
    }

    /// A custom symlink of the same shape — `filesystems.php` lets an app declare
    /// any number of these, not just `public/storage`.
    func testCustomInProjectSymlinkStillInlines() throws {
        let p = try makeProject()
        try p.write("storage/media/photo.png", "CUSTOM-LINKED-IMAGE")
        try p.symlink("public/media", to: "../storage/media")

        assertInlined(try render(p, #"<img src="/media/photo.png">"#),
                      "CUSTOM-LINKED-IMAGE", "a custom in-project symlink under public/")
    }

    /// The security half of the same mechanism: a symlink that leaves the PROJECT
    /// must still be refused, or containment buys nothing against a hostile project.
    func testSymlinkEscapingTheProjectIsBlocked() throws {
        let p = try makeProject()
        try p.symlink("public/escape", to: p.outside.path)

        assertNoLeak(try render(p, #"<img src="/escape/canary.png">"#),
                     "symlink under public/ pointing outside the project")
    }

    func testSymlinkEscapingTheProjectFromCSSIsBlocked() throws {
        let p = try makeProject()
        try p.symlink("public/escape", to: p.outside.path)
        try p.write("public/build/assets/app.css",
                    "body{background:url(/escape/canary.png)}")

        assertNoLeak(try render(p, "<p>hi</p>"),
                     "CSS url() through a symlink pointing outside the project")
    }

    func testLegitimateFontAwesomeWebfontStillInlines() throws {
        let p = try makeProject()
        try p.write("public/fonts/css/all.min.css", "@font-face{src:url(../webfonts/fa.woff2)}")
        try p.write("public/fonts/webfonts/fa.woff2", "FA-WEBFONT")
        assertInlined(try render(p, #"<i class="fa-solid fa-user"></i>"#),
                      "FA-WEBFONT", "ordinary FontAwesome webfont inlining")
    }
}
