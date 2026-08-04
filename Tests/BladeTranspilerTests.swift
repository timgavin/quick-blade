import XCTest

final class BladeTranspilerTests: XCTestCase {

    func testSmokeStripsIfDirectiveKeepsContent() {
        let out = BladeTranspiler.transpile("@if($x)<p>Hi</p>@endif")
        XCTAssertTrue(out.contains("<p>Hi</p>"))
        XCTAssertFalse(out.contains("@if"))
        XCTAssertFalse(out.contains("@endif"))
    }

    // MARK: - Auth-family branch selection (preview = authenticated user)

    func testGuestElseKeepsAuthenticatedBranch() {
        let out = BladeTranspiler.transpile("@guest<a>Login</a>@else<a>Profile</a>@endguest")
        XCTAssertFalse(out.contains("Login"))
        XCTAssertTrue(out.contains("Profile"))
    }

    func testGuestWithoutElseIsDropped() {
        let out = BladeTranspiler.transpile("<nav>@guest<a>Login</a>@endguest</nav>")
        XCTAssertFalse(out.contains("Login"))
        XCTAssertTrue(out.contains("<nav>"))
    }

    func testAuthElseDropsGuestBranch() {
        let out = BladeTranspiler.transpile("@auth<a>Dashboard</a>@else<a>Login</a>@endauth")
        XCTAssertTrue(out.contains("Dashboard"))
        XCTAssertFalse(out.contains("Login"))
    }

    func testAuthWithGuardArgument() {
        let out = BladeTranspiler.transpile("@auth('web')<p>In</p>@else<p>Out</p>@endauth")
        XCTAssertTrue(out.contains("<p>In</p>"))
        XCTAssertFalse(out.contains("<p>Out</p>"))
    }

    // The critical nesting case: an inner @if's @else must not be mistaken
    // for the @auth block's own @else.
    func testNestedIfElseInsideAuthKeepsBothIfBranches() {
        let src = "@auth @if($a)<p>A</p>@else<p>B</p>@endif @else<p>Guest</p>@endauth"
        let out = BladeTranspiler.transpile(src)
        XCTAssertTrue(out.contains("<p>A</p>"))
        XCTAssertTrue(out.contains("<p>B</p>"))   // @if shows all branches by design
        XCTAssertFalse(out.contains("<p>Guest</p>"))
    }

    func testNestedIfInsideGuestElseBranchSurvives() {
        // Note the space in `@endif @else` — Blade's \B@ rule means a glued
        // `@endif@else` is literal text in real Laravel, not two directives.
        let src = "@guest<p>Login</p>@if($x)<p>X</p>@endif @else<p>Menu</p>@endguest"
        let out = BladeTranspiler.transpile(src)
        XCTAssertFalse(out.contains("Login"))
        XCTAssertFalse(out.contains("<p>X</p>"))
        XCTAssertTrue(out.contains("<p>Menu</p>"))
    }

    func testCanKeepsFirstBranchCannotKeepsElse() {
        let can = BladeTranspiler.transpile("@can('edit', $post)<p>Edit</p>@else<p>NoEdit</p>@endcan")
        XCTAssertTrue(can.contains("<p>Edit</p>"))
        XCTAssertFalse(can.contains("<p>NoEdit</p>"))
        let cannot = BladeTranspiler.transpile("@cannot('edit', $post)<p>Denied</p>@else<p>Allowed</p>@endcannot")
        XCTAssertFalse(cannot.contains("<p>Denied</p>"))
        XCTAssertTrue(cannot.contains("<p>Allowed</p>"))
    }

    func testSessionIfElseKeepsElseBranch() {
        let src = "@if(session('status'))<p>Flash</p>@else<p>Normal</p>@endif"
        let out = BladeTranspiler.transpile(src)
        XCTAssertFalse(out.contains("Flash"))
        XCTAssertTrue(out.contains("Normal"))
    }

    func testPlainIfStillShowsAllBranches() {
        let out = BladeTranspiler.transpile("@if($a)<p>A</p>@else<p>B</p>@endif")
        XCTAssertTrue(out.contains("<p>A</p>"))
        XCTAssertTrue(out.contains("<p>B</p>"))
    }

    // Consecutive blocks: an earlier @if block must not swallow or block a
    // following @guest block.
    func testSequentialBlocksBothResolve() {
        let src = "@if($x)<p>X</p>@endif\n@guest<a>Login</a>@else<a>Profile</a>@endguest"
        let out = BladeTranspiler.transpile(src)
        XCTAssertTrue(out.contains("<p>X</p>"))
        XCTAssertFalse(out.contains("Login"))
        XCTAssertTrue(out.contains("Profile"))
    }

    func testAdminBlockKeepsElseBranch() {
        let out = BladeTranspiler.transpile("@admin<p>AdminPanel</p>@else<p>UserView</p>@endadmin")
        XCTAssertFalse(out.contains("AdminPanel"))
        XCTAssertTrue(out.contains("<p>UserView</p>"))
    }

    func testSessionDirectiveBlockIsDropped() {
        let out = BladeTranspiler.transpile("<div>@session('status')<p>Flash</p>@endsession</div>")
        XCTAssertFalse(out.contains("Flash"))
        XCTAssertTrue(out.contains("<div>"))
    }

    // An email domain must neither open a block nor prevent the real block
    // after it from resolving.
    func testEmailDomainDoesNotOpenAuthBlock() {
        let src = "<p>Contact sales@auth.io</p>@auth<p>In</p>@else<p>Out</p>@endauth"
        let out = BladeTranspiler.transpile(src)
        XCTAssertTrue(out.contains("sales@auth.io"))
        XCTAssertTrue(out.contains("<p>In</p>"))
        XCTAssertFalse(out.contains("<p>Out</p>"))
    }

    // MARK: - Placeholder expansion by attribute context

    func testValueAttributeEchoGetsFakeValue() {
        let out = BladeTranspiler.transpile(#"<input type="text" value="{{ old('name') }}">"#)
        XCTAssertTrue(out.contains("value=\"Jane Doe\""), "got: \(out)")
    }

    func testImgSrcEchoBecomesPlaceholderSVG() {
        let out = BladeTranspiler.transpile(#"<img src="{{ $dynamicUrl }}">"#)
        XCTAssertTrue(out.contains("src=\"data:image/svg+xml,"), "got: \(out)")
    }

    func testBodyEchoGetsFakeName() {
        let out = BladeTranspiler.transpile("<p>{{ $user->name }}</p>")
        XCTAssertTrue(out.contains("<p>Jane Doe</p>"), "got: \(out)")
    }

    func testAltAndTitleAttrsGetFakeValues() {
        let out = BladeTranspiler.transpile(#"<img alt="{{ $user->name }}" src="/x.png">"#)
        XCTAssertTrue(out.contains("alt=\"Jane Doe\""), "got: \(out)")
    }

    func testNonImgSrcLikeAttrsKeepHash() {
        // srcset is a hash attr but not an img src → stays "#"
        let out = BladeTranspiler.transpile(#"<source srcset="{{ $set }}">"#)
        XCTAssertTrue(out.contains("srcset=\"#\""), "got: \(out)")
    }

    func testRawEchoInBodyGetsFakeValue() {
        let out = BladeTranspiler.transpile("<div>{!! $post->body !!}</div>")
        XCTAssertTrue(out.contains("A short sample sentence"), "got: \(out)")
    }

    func testBodyEchoUnknownYieldsSample() {
        let out = BladeTranspiler.transpile("<p>{{ $widget }}</p>")
        XCTAssertTrue(out.contains("<p>Sample</p>"), "got: \(out)")
    }

    func testHrefEchoStaysHash() {
        let out = BladeTranspiler.transpile(#"<a href="{{ route('login') }}">Go</a>"#)
        XCTAssertTrue(out.contains("href=\"#\""))
    }

    func testClassAttributeEchoBecomesEmpty() {
        let out = BladeTranspiler.transpile(#"<div class="a {{ $cls }} b">x</div>"#)
        XCTAssertFalse(out.contains("#"))
        XCTAssertTrue(out.contains("class=\"a "))
    }

    func testUnquotedAttrEchoStaysHash() {
        let out = BladeTranspiler.transpile("<div data-id={{ $id }}>x</div>")
        XCTAssertTrue(out.contains("data-id=#"))
    }

    func testTranslationWithArgumentsKeepsText() {
        let out = BladeTranspiler.transpile(#"<p>{{ __('Hello :name', ['name' => auth()->user()->name]) }}</p>"#)
        XCTAssertTrue(out.contains("Hello :name"))
    }

    func testPlainTranslationStillWorks() {
        let out = BladeTranspiler.transpile(#"<p>{{ __('Log in') }}</p>"#)
        XCTAssertTrue(out.contains("Log in"))
    }

    // Not a proof of thread safety — a crash canary. Fails loudly (crashes the
    // test runner) if cachedRegex races under concurrent transpiles.
    func testConcurrentTranspileDoesNotCrash() {
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            _ = BladeTranspiler.transpile("@if($x\(i))<p>Hi {{ $name\(i) }}</p>@endif")
        }
    }

    // MARK: - Loop expansion

    func testForeachBodyRepeatsThreeTimes() {
        let out = BladeTranspiler.transpile("<ul>@foreach($users as $user)<li>ROW</li>@endforeach</ul>")
        XCTAssertEqual(out.components(separatedBy: "ROW").count - 1, 3, "got: \(out)")
        XCTAssertFalse(out.contains("@foreach"))
        XCTAssertFalse(out.contains("@endforeach"))
    }

    func testForeachPersonasVaryAcrossRows() {
        let out = BladeTranspiler.transpile("@foreach($users as $user)<td>{{ $user->name }}</td>@endforeach")
        XCTAssertTrue(out.contains("Jane Doe"), "got: \(out)")
        XCTAssertTrue(out.contains("John Smith"), "got: \(out)")
        XCTAssertTrue(out.contains("Alex Rivera"), "got: \(out)")
    }

    func testForelseDropsEmptyBranch() {
        let out = BladeTranspiler.transpile(
            "@forelse($posts as $post)<li>ITEM</li>@empty<p>No posts yet</p>@endforelse")
        XCTAssertEqual(out.components(separatedBy: "ITEM").count - 1, 3, "got: \(out)")
        XCTAssertFalse(out.contains("No posts yet"))
    }

    func testNestedLoopsCappedAtTwoLevels() {
        let src = "@foreach($a as $x)L1 @foreach($b as $y)L2 @foreach($c as $z)L3 @endforeach @endforeach @endforeach"
        let out = BladeTranspiler.transpile(src)
        XCTAssertEqual(out.components(separatedBy: "L1").count - 1, 3, "got: \(out)")
        XCTAssertEqual(out.components(separatedBy: "L2").count - 1, 9, "got: \(out)")
        // Level 3 renders once per enclosing L2 copy (9), NOT 27.
        XCTAssertEqual(out.components(separatedBy: "L3").count - 1, 9, "got: \(out)")
    }

    // Blade's \B@ rule: a directive glued to a preceding word character is
    // literal text and must not expand. (Phase 2's generic stripping still
    // removes the stray tokens, so the body renders once, not three times.)
    func testGluedForeachDoesNotExpand() {
        let out = BladeTranspiler.transpile("x@foreach($a as $b)ROW@endforeach")
        XCTAssertEqual(out.components(separatedBy: "ROW").count - 1, 1, "got: \(out)")
    }

    // Spec pin: @verbatim content inside a repeated loop body survives
    // untouched in every copy (parked before expansion, restored after).
    func testVerbatimBlockInsideLoopSurvivesUntouched() {
        let src = "@foreach($a as $b)@verbatim{{ raw }}@endverbatim@endforeach"
        let out = BladeTranspiler.transpile(src)
        XCTAssertEqual(out.components(separatedBy: "{{ raw }}").count - 1, 3, "got: \(out)")
        XCTAssertFalse(out.contains("QBITER"))
        XCTAssertFalse(out.contains("QUICKBLADE_VERBATIM"))
    }

    // Spec pin: parked <style> content is untouched by directive stripping
    // and loop expansion happening around it.
    func testStyleBlockContentIsNotTranspiled() {
        let src = "<style>@media (min-width: 600px) { .x { color: red; } }</style>@foreach($a as $b)<i>R</i>@endforeach"
        let out = BladeTranspiler.transpile(src)
        XCTAssertTrue(out.contains("@media (min-width: 600px)"), "got: \(out)")
        XCTAssertEqual(out.components(separatedBy: "<i>R</i>").count - 1, 3, "got: \(out)")
    }

    // Pin for expandLoops' cursor arithmetic: two sequential top-level loops
    // must both expand (the second must not be skipped or re-scanned).
    func testTwoSequentialTopLevelLoopsBothExpand() {
        let src = "@foreach($a as $x)<li>NAV</li>@endforeach<table>@forelse($b as $y)<tr>ROW</tr>@empty<p>none</p>@endforelse</table>"
        let out = BladeTranspiler.transpile(src)
        XCTAssertEqual(out.components(separatedBy: "NAV").count - 1, 3, "got: \(out)")
        XCTAssertEqual(out.components(separatedBy: "ROW").count - 1, 3, "got: \(out)")
        XCTAssertFalse(out.contains("none"))
    }

    func testForLoopBodyStillRendersOnce() {
        let out = BladeTranspiler.transpile("@for($i = 0; $i < 5; $i++)<span>DOT</span>@endfor")
        XCTAssertEqual(out.components(separatedBy: "DOT").count - 1, 1, "got: \(out)")
    }

    func testTranslationInsideLoopStillResolves() {
        let out = BladeTranspiler.transpile("@foreach($items as $item)<a>{{ __('Delete') }}</a>@endforeach")
        XCTAssertEqual(out.components(separatedBy: "Delete").count - 1, 3, "got: \(out)")
    }

    func testEscapedEchoInsideLoopStaysLiteral() {
        let out = BladeTranspiler.transpile("@foreach($items as $item)@{{ vue }}@endforeach")
        XCTAssertEqual(out.components(separatedBy: "{{ vue }}").count - 1, 3, "got: \(out)")
        XCTAssertFalse(out.contains("QBITER"))
    }

    func testNoMarkerLeaksIntoOutput() {
        let out = BladeTranspiler.transpile(
            "@foreach($users as $user)<p>{{ $user->name }} {!! $user->bio !!}</p>@endforeach")
        XCTAssertFalse(out.contains("QBITER"), "got: \(out)")
    }

    // MARK: - Literal ternaries + whole-src img placeholder (task 12)

    func testImgSrcWithLiteralPrefixBecomesWholePlaceholder() {
        let out = BladeTranspiler.transpile(#"<img src="https://cdn.example.com/img/{{ $location->location->url }}" class="rounded">"#)
        XCTAssertTrue(out.contains("src=\"data:image/svg+xml,"), "got: \(out)")
        XCTAssertFalse(out.contains("cdn.example.com"), "literal prefix must not survive: \(out)")
        XCTAssertTrue(out.contains("class=\"rounded\""))
    }

    func testLiteralTernaryResolvesToFirstBranch() {
        let out = BladeTranspiler.transpile("<span>{{ $growth >= 0 ? '+' : '-' }}{{ abs($a['trends']['revenue_growth']) }}%</span>")
        XCTAssertTrue(out.contains("<span>+12%</span>"), "got: \(out)")
    }

    func testNullCoalesceIsNotATernary() {
        let out = BladeTranspiler.transpile("<p>{{ $subtitle ?? 'fallback' }}</p>")
        XCTAssertFalse(out.contains("fallback' }}"), "half-matched coalesce: \(out)")
        // Full observed behavior: the null-coalesce isn't a ternary, so it falls
        // through to the normal placeholder → FakeData path. "subtitle" (quotes
        // stripped) matches no word rule, so it resolves to the generic fallback.
        XCTAssertTrue(out.contains("<p>Sample</p>"), "got: \(out)")
    }

    func testFluxBadgeColorTernaryResolves() {
        let out = BladeTranspiler.transpile(#"<flux:badge color="{{ $g >= 0 ? 'green' : 'red' }}" size="sm">x</flux:badge>"#)
        XCTAssertTrue(out.contains("data-flux-color=\"green\""), "got: \(out)")
    }

    func testFluxSelectOptionsBecomeRealOptions() {
        let out = BladeTranspiler.transpile(
            #"<flux:select wire:model="period"><flux:select.option value="30d">Last 30 days</flux:select.option></flux:select>"#)
        XCTAssertTrue(out.contains("<option"), "got: \(out)")
        XCTAssertTrue(out.contains("Last 30 days"))
        XCTAssertFalse(out.contains("data-flux-generic"))
    }

    // MARK: - Preview doctrine: no validation errors

    func testErrorBlocksDropWithContent() {
        let out = BladeTranspiler.transpile("@error('email')<span class=\"err\">{{ $message }}</span>@enderror<p>after</p>")
        XCTAssertFalse(out.contains("err"), "got: \(out)")
        XCTAssertTrue(out.contains("<p>after</p>"))
    }

    func testErrorIterableLoopsDropEntirely() {
        let out = BladeTranspiler.transpile("<ul>@foreach((array) $messages as $message)<li>{{ $message }}</li>@endforeach</ul><p>after</p>")
        XCTAssertFalse(out.contains("<li>"), "got: \(out)")
        XCTAssertTrue(out.contains("<p>after</p>"))
    }

    func testNonErrorLoopWithMessageVariableStillExpands() {
        let out = BladeTranspiler.transpile("@foreach($items as $message)<li>ROW</li>@endforeach")
        XCTAssertEqual(out.components(separatedBy: "ROW").count - 1, 3, "got: \(out)")
    }
}
