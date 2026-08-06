import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class TemplateResolverTests: XCTestCase {

    private func resolve(page: String, files: [String: String]) throws -> TemplateResolver.Result {
        let project = try FixtureProject()
        for (path, contents) in files {
            try project.write(path, contents)
        }
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        return TemplateResolver.resolve(source: page, fileURL: pageURL)
    }

    func testComposesLayoutWithNoSpaceSlotEcho() throws {
        let result = try resolve(
            page: "<x-layouts.app><p>CONTENT</p></x-layouts.app>",
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>{{$slot}}</body></html>"])
        XCTAssertTrue(result.didResolveLayout)
        XCTAssertTrue(result.html.contains("<p>CONTENT</p>"))
    }

    func testNamedSlotFillsBareEcho() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-slot:header>HEAD</x-slot:header><p>BODY</p></x-layouts.app>",
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body><header>{{ $header }}</header>{{ $slot }}</body></html>"])
        XCTAssertTrue(result.html.contains("<header>HEAD</header>"))
        XCTAssertTrue(result.html.contains("<p>BODY</p>"))
    }

    func testNamedSlotAttributeSyntax() throws {
        let result = try resolve(
            page: #"<x-layouts.app><x-slot name="header">HEAD</x-slot><p>BODY</p></x-layouts.app>"#,
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body><header>{{ $header ?? '' }}</header>{{ $slot }}</body></html>"])
        XCTAssertTrue(result.html.contains("<header>HEAD</header>"))
        XCTAssertFalse(result.html.contains("HEAD</p>"), "slot content leaked into default slot")
    }

    func testSlotContentContainingDollarSignSurvives() throws {
        let result = try resolve(
            page: "<x-layouts.app><p>Price: $100</p></x-layouts.app>",
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>{{ $slot }}</body></html>"])
        XCTAssertTrue(result.html.contains("Price: $100"))
    }

    func testEchoWithNullCoalescingFallbackGetsSlot() throws {
        let result = try resolve(
            page: "<x-layouts.app><p>BODY</p></x-layouts.app>",
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>{{ $slot ?? '' }}</body></html>"])
        XCTAssertTrue(result.html.contains("<p>BODY</p>"))
    }

    // MARK: - @extends / @section / @yield

    func testExtendsWithStopTerminator() throws {
        let result = try resolve(
            page: "@extends('layouts.app')\n@section('content')<p>PAGE</p>@stop",
            files: ["resources/views/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>@yield('content')</body></html>"])
        XCTAssertTrue(result.didResolveLayout)
        XCTAssertTrue(result.html.contains("<p>PAGE</p>"))
    }

    func testYieldWithDefaultUsesProvidedSection() throws {
        let result = try resolve(
            page: "@extends('layouts.app')\n@section('title', 'My Page')\n@section('content')<p>B</p>@endsection",
            files: ["resources/views/layouts/app.blade.php":
                "<!DOCTYPE html><html><head><title>@yield('title', 'Fallback')</title></head><body>@yield('content')</body></html>"])
        XCTAssertTrue(result.html.contains("My Page"))
        XCTAssertFalse(result.html.contains("Fallback"))
    }

    func testLayoutSectionShowUsesPageOverride() throws {
        let result = try resolve(
            page: "@extends('layouts.app')\n@section('sidebar')<p>CUSTOM</p>@endsection\n@section('content')<p>B</p>@endsection",
            files: ["resources/views/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>@section('sidebar')<p>DEFAULT</p>@show @yield('content')</body></html>"])
        XCTAssertTrue(result.html.contains("<p>CUSTOM</p>"))
        XCTAssertFalse(result.html.contains("<p>DEFAULT</p>"))
    }

    func testLayoutSectionShowKeepsDefaultWhenNotOverridden() throws {
        let result = try resolve(
            page: "@extends('layouts.app')\n@section('content')<p>B</p>@endsection",
            files: ["resources/views/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>@section('sidebar')<p>DEFAULT</p>@show @yield('content')</body></html>"])
        XCTAssertTrue(result.html.contains("<p>DEFAULT</p>"))
    }

    // MARK: - Image inlining

    /// 1x1 transparent PNG.
    static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    func testAssetEchoImageIsInlined() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/layouts/app.blade.php",
            "<!DOCTYPE html><html><body>{{ $slot }}</body></html>")
        try project.write("public/images/logo.png", data: Self.tinyPNG)
        let page = #"<x-layouts.app><img src="{{ asset('images/logo.png') }}"></x-layouts.app>"#
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        let result = TemplateResolver.resolve(source: page, fileURL: pageURL)
        XCTAssertTrue(result.html.contains("data:image/png;base64,"), "asset() image was not inlined")
    }

    func testRootRelativeCSSUrlIsInlined() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/layouts/app.blade.php",
            "<!DOCTYPE html><html><head>@vite(['resources/css/app.css'])</head><body>{{ $slot }}</body></html>")
        try project.write("public/build/assets/app-abc123.css",
            ".hero{background:url(/images/bg.png)}")
        try project.write("public/images/bg.png", data: Self.tinyPNG)
        let page = "<x-layouts.app><p>X</p></x-layouts.app>"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        let result = TemplateResolver.resolve(source: page, fileURL: pageURL)
        XCTAssertTrue(result.didInlineCSS)
        XCTAssertTrue(result.html.contains("url(data:image/png;base64,"), "root-relative CSS url was not inlined")
    }

    // MARK: - Dark mode class bridge

    // Compiled Tailwind/Flux dark variants are class-gated (`.dark` on <html>),
    // normally added by app JS living in the never-loaded Vite bundle. The preview
    // DOES run inline JS (FINDINGS §10), so when compiled CSS is inlined the
    // resolver injects a script that mirrors the system appearance onto the root.
    func testDarkClassBridgeScriptInjectedOnLayoutPath() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/layouts/app.blade.php",
            "<!DOCTYPE html><html><head>@vite(['resources/css/app.css'])</head><body>{{ $slot }}</body></html>")
        try project.write("public/build/assets/app-abc123.css",
            ".dark\\:bg-zinc-950:where(.dark, .dark *){background:#09090b}")
        let page = "<x-layouts.app><p>X</p></x-layouts.app>"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        let result = TemplateResolver.resolve(source: page, fileURL: pageURL)
        XCTAssertTrue(result.html.contains("classList.add(\"dark\")"),
                      "dark class bridge script missing on layout path")
    }

    func testDarkClassBridgeScriptInjectedOnBarePagePath() throws {
        let project = try FixtureProject()
        try project.write("public/build/assets/app-abc123.css", ".x{color:red}")
        let page = "<div><p>Nested component</p></div>"
        let pageURL = try project.write("resources/views/livewire/widget.blade.php", page)
        let result = TemplateResolver.resolve(source: page, fileURL: pageURL)
        XCTAssertTrue(result.html.contains("classList.add(\"dark\")"),
                      "dark class bridge script missing on bare-page path")
    }

    func testSingleQuotedImgSrcIsInlined() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/layouts/app.blade.php",
            "<!DOCTYPE html><html><body>{{ $slot }}</body></html>")
        try project.write("public/images/logo.png", data: Self.tinyPNG)
        let page = "<x-layouts.app><img src='/images/logo.png'></x-layouts.app>"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        let result = TemplateResolver.resolve(source: page, fileURL: pageURL)
        XCTAssertTrue(result.html.contains("data:image/png;base64,"))
    }

    func testOversizedImageIsDownscaledNotDropped() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/layouts/app.blade.php",
            "<!DOCTYPE html><html><body>{{ $slot }}</body></html>")
        try project.write("public/images/hero.png", data: Self.makeLargePNG())
        let page = #"<x-layouts.app><img src="/images/hero.png"></x-layouts.app>"#
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        let result = TemplateResolver.resolve(source: page, fileURL: pageURL)
        XCTAssertTrue(result.html.contains("data:image/jpeg;base64,"), "oversized image should downscale to JPEG")
    }

    /// Renders a noisy 2000×2000 PNG guaranteed to exceed the 500KB inline cap.
    static func makeLargePNG() -> Data {
        let size = 2000
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<pixels.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let cfData = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: cfData)!
        let cg = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testCompiledCSSConcatenationIsAlphabetical() throws {
        let project = try FixtureProject()
        try project.write("resources/views/components/layouts/app.blade.php",
            "<!DOCTYPE html><html><head>@vite(['resources/css/app.css'])</head><body>{{ $slot }}</body></html>")
        try project.write("public/build/assets/zeta-1.css", ".z{color:red}")
        try project.write("public/build/assets/alpha-1.css", ".a{color:blue}")
        let page = "<x-layouts.app><p>X</p></x-layouts.app>"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        let result = TemplateResolver.resolve(source: page, fileURL: pageURL)
        guard let aPos = result.html.range(of: ".a{color:blue}")?.lowerBound,
              let zPos = result.html.range(of: ".z{color:red}")?.lowerBound else {
            return XCTFail("both CSS files should be inlined")
        }
        XCTAssertLessThan(aPos, zPos, "CSS must concatenate in stable alphabetical order")
    }

    // MARK: - Component edge cases

    func testSelfClosingInsidePairedSameNameComponent() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-card><p>KEEP</p><x-card /></x-card></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/card.blade.php":
                    "<div class=\"card\">{{ $slot }}</div>",
            ])
        XCTAssertTrue(result.html.contains("<p>KEEP</p>"))
        XCTAssertTrue(result.html.contains("class=\"card\""))
        // Discriminating assertion: KEEP must be NESTED INSIDE the card div.
        // In the pre-fix corruption the card div is empty and KEEP floats
        // beside a dangling literal <x-card> tag, yet both substrings above
        // still appear — only this one distinguishes fixed from broken.
        XCTAssertTrue(result.html.contains("<div class=\"card\"><p>KEEP</p>"))
    }

    func testLayoutFoundWhenPrecededBySelfClosingComponent() throws {
        let result = try resolve(
            page: "<x-banner />\n<x-layouts.app><p>BODY</p></x-layouts.app>",
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>{{ $slot }}</body></html>"])
        XCTAssertTrue(result.didResolveLayout)
        XCTAssertTrue(result.html.contains("<p>BODY</p>"))
        // Bare-page fallback wraps content in <main class="qb-page">; the real
        // layout does not. This is what distinguishes the two paths.
        XCTAssertFalse(result.html.contains("qb-page"),
                       "page fell back to bare-page render instead of composing the layout")
    }

    func testAbsoluteUrlEchoIsNotRewritten() throws {
        let result = try resolve(
            page: #"<x-layouts.app><a href="{{ url('https://example.com/x') }}">Go</a></x-layouts.app>"#,
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>{{ $slot }}</body></html>"])
        XCTAssertFalse(result.html.contains("/https://"), "absolute URL was wrongly path-prefixed")
    }

    func testSelfClosingComponentIsInlined() throws {
        let result = try resolve(
            page: "<x-layouts.app><form><x-text-input id=\"username\" type=\"text\" /></form></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/text-input.blade.php":
                    "<input {{ $attributes }} class=\"ti\" />",
            ])
        XCTAssertTrue(result.html.contains("<input"), "got: \(result.html)")
        XCTAssertTrue(result.html.contains("class=\"ti\""))
    }

    func testUnresolvableSelfClosingComponentIsLeftForStripping() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-vendor-widget size=\"invisible\" /><p>after</p></x-layouts.app>",
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>{{ $slot }}</body></html>"])
        // Resolver leaves it; the transpiler strips it later. Both true here:
        XCTAssertTrue(result.html.contains("<x-vendor-widget") || !result.html.contains("vendor-widget"))
        XCTAssertTrue(result.html.contains("<p>after</p>"))
    }

    func testInlineComponentNamedSlotFillsHeadingEcho() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-auth-card><x-slot name=\"heading\">Welcome Back</x-slot><p>BODY</p></x-auth-card></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/auth-card.blade.php":
                    "<div class=\"card\"><h1>{{ $heading }}</h1>{{ $slot }}</div>",
            ])
        XCTAssertTrue(result.html.contains("<h1>Welcome Back</h1>"), "got: \(result.html)")
        XCTAssertTrue(result.html.contains("<p>BODY</p>"))
        XCTAssertFalse(result.html.contains("<x-slot"))
    }

    func testSelfClosingInsidePairedComponentResolves() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-auth-card><x-text-input type=\"text\" /></x-auth-card></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/auth-card.blade.php":
                    "<div class=\"card\">{{ $slot }}</div>",
                "resources/views/components/text-input.blade.php":
                    "<input class=\"ti\" />",
            ])
        XCTAssertTrue(result.html.contains("<input class=\"ti\" />"), "got: \(result.html)")
    }

    // MARK: - Diagnostics

    func testCleanResolveHasNoIssues() throws {
        let result = try resolve(
            page: "<x-layouts.app><p>Hi</p></x-layouts.app>",
            files: ["resources/views/components/layouts/app.blade.php":
                "<!DOCTYPE html><html><body>{{ $slot }}</body></html>"])
        XCTAssertFalse(result.diagnostics.hasIssue)
    }

    func testNoLaravelRootIsSilent() throws {
        // A readable directory with no artisan anywhere above it → expected fallback, no issue.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-noroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let pageURL = base.appendingPathComponent("page.blade.php")
        try "<p>Hi</p>".data(using: .utf8)!.write(to: pageURL)
        let result = TemplateResolver.resolve(source: "<p>Hi</p>", fileURL: pageURL)
        XCTAssertFalse(result.diagnostics.hasIssue)
    }

    func testExtendsMissingLayoutSetsLayoutMissing() throws {
        let result = try resolve(
            page: "@extends('layouts.gone')\n@section('content')<p>Hi</p>@endsection",
            files: [:])
        XCTAssertTrue(result.diagnostics.layoutMissing)
        XCTAssertFalse(result.diagnostics.readDenied)
    }

    func testUnreadableExtendsLayoutSetsReadDenied() throws {
        let project = try FixtureProject()
        let layout = try project.write("resources/views/layouts/app.blade.php",
            "<!DOCTYPE html><html><body>@yield('content')</body></html>")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: layout.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: layout.path) }
        let page = "@extends('layouts.app')\n@section('content')<p>Hi</p>@endsection"
        let pageURL = try project.write("resources/views/pages/test.blade.php", page)
        let result = TemplateResolver.resolve(source: page, fileURL: pageURL)
        XCTAssertTrue(result.diagnostics.readDenied)
    }

    func testUnlistableParentDirectorySetsReadDenied() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-denied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let pageURL = base.appendingPathComponent("page.blade.php")
        try "<p>Hi</p>".data(using: .utf8)!.write(to: pageURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: base.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
            try? FileManager.default.removeItem(at: base)
        }
        let result = TemplateResolver.resolve(source: "<p>Hi</p>", fileURL: pageURL)
        XCTAssertTrue(result.diagnostics.readDenied)
        XCTAssertFalse(result.didResolveLayout)
    }

    // MARK: - $attributes bag (static approximation)

    func testAttributesMergeEmitsDefaultsAndCallerClassConcat() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-primary-button class=\"w-full\">Log in</x-primary-button></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/primary-button.blade.php":
                    "<button {{ $attributes->merge(['type' => 'submit', 'class' => 'btn-base px-4']) }}>{{ $slot }}</button>",
            ])
        XCTAssertTrue(result.html.contains("type=\"submit\""), "got: \(result.html)")
        XCTAssertTrue(result.html.contains("btn-base px-4 w-full"), "class concat: \(result.html)")
        XCTAssertTrue(result.html.contains(">Log in</button>") || result.html.contains("> Log in </button>")
            || result.html.range(of: #">\s*Log in\s*</button>"#, options: .regularExpression) != nil,
            "slot: \(result.html)")
    }

    func testBareAttributesEmitsCallerAttrs() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-text-input id=\"username\" type=\"text\" name=\"username\" required /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/text-input.blade.php":
                    "<input {{ $attributes }} />",
            ])
        XCTAssertTrue(result.html.contains("id=\"username\""), "got: \(result.html)")
        XCTAssertTrue(result.html.contains("type=\"text\""))
    }

    func testTranslationPropBindResolvesToText() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-input-label for=\"username\" :value=\"__('Username')\" /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/input-label.blade.php":
                    "<label {{ $attributes->merge(['class' => 'lbl']) }}>{{ $value ?? $slot }}</label>",
            ])
        XCTAssertTrue(result.html.contains(">Username</label>"), "got: \(result.html)")
        XCTAssertFalse(result.html.contains("__("))
    }

    func testRuntimeDynamicBindsAreDroppedFromAttrOutput() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-text-input :value=\"old('username')\" name=\"u\" /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/text-input.blade.php":
                    "<input {{ $attributes }} />",
            ])
        XCTAssertTrue(result.html.contains("name=\"u\""), "got: \(result.html)")
        XCTAssertFalse(result.html.contains("old("), "runtime bind leaked: \(result.html)")
    }

    func testAttributesExceptRemovesListedKeys() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-badge data-x=\"1\" title=\"T\" /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/badge.blade.php":
                    "<span {{ $attributes->except(['title']) }}>b</span>",
            ])
        XCTAssertTrue(result.html.contains("data-x=\"1\""), "got: \(result.html)")
        XCTAssertFalse(result.html.contains("title=\"T\""))
    }

    func testBareBooleanAttributesSurviveAttributesBag() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-text-input id=\"u\" required autofocus /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/text-input.blade.php":
                    "<input {{ $attributes }} />",
            ])
        XCTAssertTrue(result.html.contains("required"), "got: \(result.html)")
        XCTAssertTrue(result.html.contains("autofocus"))
        XCTAssertFalse(result.html.contains("required=\"\""))
    }

    func testCheckedSurvivesMerge() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-check name=\"a\" checked /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/check.blade.php":
                    "<input type=\"checkbox\" {{ $attributes->merge(['class' => 'cb']) }} />",
            ])
        XCTAssertTrue(result.html.contains("checked"), "got: \(result.html)")
        XCTAssertTrue(result.html.contains("class=\"cb\""))
    }

    func testDynamicPropBindSubstitutesEmptyNotRawSource() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-status-banner :status=\"session('status')\" /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/status-banner.blade.php":
                    "<div class=\"banner\">{{ $status }}</div>",
            ])
        XCTAssertFalse(result.html.contains("session("), "raw source leaked: \(result.html)")
    }

    // MARK: - @php static evaluation

    private let phpButtonComponent = """
        @props(['size' => 'lg'])

        @php
        $sizeClasses = match($size) {
            'sm', 'tiny' => 'text-[13px] px-4 py-2',
            'md' => 'text-[14px] px-5 py-3',
            'lg' => 'text-base px-7 py-3.5',
            default => 'text-base px-7 py-3.5',
        };
        @endphp

        <a href="#" class="btn rounded-full {{ $sizeClasses }}">{{ $slot }}</a>
        """

    func testPhpMatchOnCallerPropResolvesClassEcho() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-store-button size=\"sm\">Get It</x-store-button></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/store-button.blade.php": phpButtonComponent,
            ])
        XCTAssertTrue(result.html.contains("btn rounded-full text-[13px] px-4 py-2"), "got: \(result.html)")
    }

    func testPhpMatchUsesPropsDefaultWhenCallerOmitsProp() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-store-button>Get It</x-store-button></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/store-button.blade.php": phpButtonComponent,
            ])
        XCTAssertTrue(result.html.contains("btn rounded-full text-base px-7 py-3.5"), "got: \(result.html)")
    }

    func testPhpMatchConcatenationResolvesInRawEcho() throws {
        let icon = """
            @props(['slug', 'class' => 'size-5'])

            @php
            $svg = match ($slug) {
                'play' => '<svg viewBox="0 0 640 640" class="' . $class . '"><path d="M64,320 0,0"/></svg>',
                default => '',
            };
            @endphp

            {!! $svg !!}
            """
        let result = try resolve(
            page: "<x-layouts.app><x-docs.icon slug=\"play\" /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/docs/icon.blade.php": icon,
            ])
        XCTAssertTrue(
            result.html.contains("<svg viewBox=\"0 0 640 640\" class=\"size-5\"><path d=\"M64,320 0,0\"/></svg>"),
            "got: \(result.html)")
    }

    func testPhpStringAssignmentChainResolves() throws {
        let component = """
            @php
            $base = 'badge';
            $full = $base . '-active';
            @endphp
            <span class="{{ $full }}">OK</span>
            """
        let result = try resolve(
            page: "<x-layouts.app><x-badge /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/badge.blade.php": component,
            ])
        XCTAssertTrue(result.html.contains("class=\"badge-active\""), "got: \(result.html)")
    }

    func testPropsDefaultFillsEchoWhenCallerOmitsProp() throws {
        let result = try resolve(
            page: "<x-layouts.app><x-tag /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/tag.blade.php":
                    "@props(['label' => 'New'])\n<span>{{ $label }}</span>",
            ])
        XCTAssertTrue(result.html.contains("<span>New</span>"), "got: \(result.html)")
    }

    func testUnresolvablePhpAssignmentLeavesEchoForStripping() throws {
        let component = """
            @php
            $state = computeState();
            @endphp
            <div class="card {{ $state }}">X</div>
            """
        let result = try resolve(
            page: "<x-layouts.app><x-card /></x-layouts.app>",
            files: [
                "resources/views/components/layouts/app.blade.php":
                    "<!DOCTYPE html><html><body>{{ $slot }}</body></html>",
                "resources/views/components/card.blade.php": component,
            ])
        // The resolver leaves both the @php block and the echo; the transpiler
        // (which runs next in the real pipeline) strips them without leaking source.
        let transpiled = BladeTranspiler.transpile(result.html)
        XCTAssertFalse(transpiled.contains("computeState"), "raw source leaked: \(transpiled)")
        XCTAssertFalse(transpiled.contains("$state"), "unresolved echo leaked: \(transpiled)")
    }

    func testLayoutPhpMatchResolvesFromLayoutProp() throws {
        let layout = """
            @props(['width' => 'normal'])
            @php
            $widthClass = match($width) {
                'wide' => 'max-w-7xl',
                default => 'max-w-3xl',
            };
            @endphp
            <!DOCTYPE html><html><body class="{{ $widthClass }}">{{ $slot }}</body></html>
            """
        let result = try resolve(
            page: "<x-layouts.app width=\"wide\"><p>BODY</p></x-layouts.app>",
            files: ["resources/views/components/layouts/app.blade.php": layout])
        XCTAssertTrue(result.html.contains("class=\"max-w-7xl\""), "got: \(result.html)")
    }
}
