import Foundation

struct BladeTranspiler {

    // Balanced parentheses pattern — handles up to 3 levels of nesting
    // e.g. @if(count($items) > 0) or @can('update', $post)
    // Possessive quantifiers (++) on the non-paren runs prevent catastrophic
    // backtracking on unbalanced input like `@if(` + a long run with no closing `)`.
    private static let balancedParens = #"\((?:[^()]++|\((?:[^()]++|\([^()]*\))*\))*\)"#

    // MARK: - Public API

    static func transpile(_ source: String) -> String {
        // Extract @verbatim blocks before any processing — their content must be preserved as-is
        let (noVerbatim, verbatimBlocks) = extractVerbatimBlocks(source)
        // Park <style> blocks before the regex phases. Inlined compiled CSS + base64 fonts can be
        // >1MB and contain no Blade, so scanning them with ~40 regex passes was the dominant cost
        // (1.6s on large pages). Parking drops transpile to tens of ms. Restored after the phases.
        let (cleaned, styleBlocks) = extractStyleBlocks(noVerbatim)
        var result = cleaned
        // Expand namespaced components (Flux `<flux:*>`, Livewire `<livewire:*>`) to plain
        // styled HTML before directive processing. These can't be inlined from their source
        // templates (Flux uses the `Flux::` facade + `@blaze`), so we rewrite the tags to
        // native elements carrying `data-flux-*` hooks that the shim stylesheet styles.
        result = expandNamespacedComponents(result)
        result = phase1_stripInvisible(result)
        result = expandLoops(result)
        result = phase2_stripControlFlow(result)
        result = phase3_replaceVariables(result)
        result = phase4_replaceIncludes(result)
        result = phase5_cleanWhitespace(result)
        // Restore Blade's @@ escape (literal @) after all directive/variable processing.
        result = result.replacingOccurrences(of: "QUICKBLADE_AT_", with: "@")
        result = restoreStyleBlocks(result, blocks: styleBlocks)
        result = restoreVerbatimBlocks(result, blocks: verbatimBlocks)
        return result
    }

    // MARK: - Style Block Extraction (performance)

    /// Parks `<style>…</style>` blocks behind inert placeholders so the transpiler's regex phases
    /// don't scan the (often >1MB) inlined CSS + base64 fonts. Compiled CSS carries no Blade, so
    /// this is safe; the blocks are restored verbatim after all phases.
    private static func extractStyleBlocks(_ source: String) -> (cleaned: String, blocks: [(placeholder: String, content: String)]) {
        guard let regex = try? NSRegularExpression(
            pattern: #"<style\b[^>]*>[\s\S]*?</style>"#,
            options: [.caseInsensitive]
        ) else { return (source, []) }

        let nsSource = source as NSString
        let matches = regex.matches(in: source, options: [], range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else { return (source, []) }

        var result = source
        var blocks: [(placeholder: String, content: String)] = []
        for (i, match) in matches.enumerated().reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            let content = String(result[fullRange])
            // See extractVerbatimBlocks below for why placeholders use HTML-comment
            // delimiters rather than a bare trailing underscore.
            let placeholder = "<!--QUICKBLADE_STYLE_\(i)-->"
            blocks.append((placeholder: placeholder, content: content))
            result.replaceSubrange(fullRange, with: placeholder)
        }
        return (result, blocks)
    }

    private static func restoreStyleBlocks(_ source: String, blocks: [(placeholder: String, content: String)]) -> String {
        var result = source
        for block in blocks {
            result = result.replacingOccurrences(of: block.placeholder, with: block.content)
        }
        return result
    }

    // MARK: - Verbatim Block Extraction

    /// Extracts `@verbatim...@endverbatim` blocks and replaces them with inert placeholders.
    /// Content inside verbatim blocks must not be processed by any transpiler phase.
    private static func extractVerbatimBlocks(_ source: String) -> (cleaned: String, blocks: [(placeholder: String, content: String)]) {
        guard let regex = try? NSRegularExpression(
            pattern: #"@verbatim([\s\S]*?)@endverbatim"#,
            options: []
        ) else { return (source, []) }

        let nsSource = source as NSString
        let matches = regex.matches(in: source, options: [], range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else { return (source, []) }

        var result = source
        var blocks: [(placeholder: String, content: String)] = []

        for (i, match) in matches.enumerated().reversed() {
            guard let contentRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let content = String(result[contentRange])
            // HTML-comment delimiters, not a bare trailing "_": the closing "-->" still
            // stops e.g. _1 from matching inside _10 (same job the old trailing underscore
            // did), but ALSO ends the placeholder on a non-word character. That matters
            // because expandLoops' Blade-fidelity lookbehind `(?<![\w@])` treats a
            // directive glued to a preceding word character as literal text, not a
            // directive (mirrors Blade's own \B@ rule). A bare "QUICKBLADE_VERBATIM_0_"
            // placeholder sitting directly before "@endforeach" made that underscore look
            // like part of the same token, so the closer was invisible to the scanner and
            // real loops silently failed to expand. Ending on "-->" keeps that lookbehind
            // seeing a genuine directive boundary.
            let placeholder = "<!--QUICKBLADE_VERBATIM_\(i)-->"
            blocks.append((placeholder: placeholder, content: content))
            result.replaceSubrange(fullRange, with: placeholder)
        }

        return (result, blocks)
    }

    /// Restores verbatim block content after all transpiler phases have completed.
    private static func restoreVerbatimBlocks(_ source: String, blocks: [(placeholder: String, content: String)]) -> String {
        var result = source
        for block in blocks {
            result = result.replacingOccurrences(of: block.placeholder, with: block.content)
        }
        return result
    }

    // MARK: - Phase 1: Strip invisible directives (remove entirely)

    private static func phase1_stripInvisible(_ source: String) -> String {
        var result = source

        // Park Blade's @@ escape (renders a literal @) before any directive stripping,
        // so matchers like @if / @section don't consume the second @. Restored in transpile().
        result = regexReplace(result, pattern: #"@@"#, with: "QUICKBLADE_AT_")

        // Blade comments: {{-- ... --}} (can be multiline)
        result = regexReplace(result, pattern: #"\{\{--[\s\S]*?--\}\}"#, with: "")

        // PHP blocks: @php...@endphp (multiline)
        result = regexReplace(result, pattern: #"@php[\s\S]*?@endphp"#, with: "")

        // Push/prepend blocks: strip directive AND content between them
        result = regexReplace(result, pattern: #"@push\s*"# + balancedParens + #"[\s\S]*?@endpush"#, with: "")
        result = regexReplace(result, pattern: #"@pushIf\s*"# + balancedParens + #"[\s\S]*?@endPushIf"#, with: "")
        result = regexReplace(result, pattern: #"@pushOnce\s*"# + balancedParens + #"[\s\S]*?@endPushOnce"#, with: "")
        result = regexReplace(result, pattern: #"@prepend\s*"# + balancedParens + #"[\s\S]*?@endprepend"#, with: "")
        result = regexReplace(result, pattern: #"@prependOnce\s*"# + balancedParens + #"[\s\S]*?@endprependOnce"#, with: "")

        // Environment blocks (@production / @env) are treated like conditionals in Phase 2:
        // the directive is stripped but the content is KEPT. Stripping the content here broke
        // pages that gate their main markup behind @env(['local','production','testing']) — a
        // login page doing that rendered blank. Inline analytics inside such blocks is
        // inert in a JS-less preview, so keeping it is harmless.

        // Session blocks: no session in a static preview → keep the @else branch.
        // Depth-aware so a nested @if's @else/@endif can't truncate the block.
        result = resolveBranchDirective(result,
            openPattern: #"@if\s*\(\s*session\s*\([^)]*\)\s*\)"#,
            closeToken: "endif", keepFirstBranch: false)
        result = resolveBranchDirective(result,
            openPattern: #"@session\s*"# + balancedParens,
            closeToken: "endsession", keepFirstBranch: false)

        // The preview simulates an authenticated, authorized, non-admin user:
        // @guest/@cannot/@admin keep their @else branch; @auth/@can/@canany keep
        // their first branch. (Plain @if/@else still shows all branches — that
        // happens in Phase 2 and is intentional.)
        // (?<!\w) on openers mirrors Blade's \B@ rule — an email domain like
        // sales@auth.io is literal text and must not open a block.
        result = resolveBranchDirective(result,
            openPattern: #"(?<!\w)@guest\b(?:\s*\([^)]*\))?"#,
            closeToken: "endguest", keepFirstBranch: false)
        result = resolveBranchDirective(result,
            openPattern: #"(?<!\w)@auth\b(?:\s*\([^)]*\))?"#,
            closeToken: "endauth", keepFirstBranch: true)
        result = resolveBranchDirective(result,
            openPattern: #"@canany\s*"# + balancedParens,
            closeToken: "endcanany", keepFirstBranch: true)
        result = resolveBranchDirective(result,
            openPattern: #"@cannot\s*"# + balancedParens,
            closeToken: "endcannot", keepFirstBranch: false)
        result = resolveBranchDirective(result,
            openPattern: #"@can\s*"# + balancedParens,
            closeToken: "endcan", keepFirstBranch: true)
        result = resolveBranchDirective(result,
            openPattern: #"(?<!\w)@admin(?!\w)"#,
            closeToken: "endadmin", keepFirstBranch: false)
        // Impersonation banner (laravel-impersonate): only shown mid-impersonation at runtime;
        // strip with content so a static preview doesn't leak a stray "Log out as user" item.
        result = regexReplace(result, pattern: #"@impersonating\s*"# + balancedParens + #"[\s\S]*?@endImpersonating"#, with: "")

        // Validation errors: the preview doctrine simulates a clean, error-free submission
        // (see loop-expansion's error-iterable check below, same stance). Strip @error blocks
        // WITH their content — like @impersonating above — not just the directives, so no fake
        // error text renders under form fields. Non-greedy is safe: nested @error isn't legal
        // Blade.
        result = regexReplace(result, pattern: #"@error\s*"# + balancedParens + #"[\s\S]*?@enderror"#, with: "")

        // Livewire directives (not useful in static preview)
        result = regexReplace(result, pattern: #"@livewireScriptConfig(?!\w)"#, with: "")
        result = regexReplace(result, pattern: #"@livewireStyles(?!\w)"#, with: "")
        result = regexReplace(result, pattern: #"@livewireScripts(?!\w)"#, with: "")

        // Layout directives (single-line, remove entirely)
        result = regexReplace(result, pattern: #"@extends\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@section\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@endsection"#, with: "")
        result = regexReplace(result, pattern: #"@yield\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@stack\s*"# + balancedParens, with: "")

        // Utility directives
        result = regexReplace(result, pattern: #"@once(?!\w)"#, with: "")
        result = regexReplace(result, pattern: #"@endonce(?!\w)"#, with: "")
        // @verbatim blocks handled by extractVerbatimBlocks() before Phase 1
        result = regexReplace(result, pattern: #"@props\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@dd\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@dump\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@class\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@style\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@checked\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@selected\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@disabled\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@readonly\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@required\s*"# + balancedParens, with: "")

        // Special replacements
        result = regexReplace(result, pattern: #"@csrf(?!\w)"#,
                              with: #"<input type="hidden" name="_token" value="csrf_token">"#)

        // @method('PUT') → hidden input with captured method
        result = regexReplaceWithCapture(result,
                                         pattern: #"@method\s*\(\s*['"]([^'"]*)['"]\s*\)"#,
                                         template: #"<input type="hidden" name="_method" value="$1">"#)

        return result
    }

    // MARK: - Phase 2: Strip control flow (remove directives, keep content)

    private static func phase2_stripControlFlow(_ source: String) -> String {
        var result = source

        // Conditionals — remove the directive line, keep content between
        result = regexReplace(result, pattern: #"@if\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@elseif\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"(?<!\w)@else(?!\w)"#, with: "")
        result = regexReplace(result, pattern: #"@endif"#, with: "")
        result = regexReplace(result, pattern: #"@unless\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@endunless"#, with: "")
        result = regexReplace(result, pattern: #"@isset\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@endisset"#, with: "")
        result = regexReplace(result, pattern: #"@empty\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@endempty"#, with: "")

        // Switch
        result = regexReplace(result, pattern: #"@switch\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@case\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@break(?!\w)"#, with: "")
        result = regexReplace(result, pattern: #"@default(?!\w)"#, with: "")
        result = regexReplace(result, pattern: #"@endswitch"#, with: "")

        // Loops — remove directive, content shown once
        result = regexReplace(result, pattern: #"@foreach\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@endforeach"#, with: "")
        result = regexReplace(result, pattern: #"@for\s*"# + balancedParens, with: "")
        // (?!\w) so @endfor doesn't eat the @endfor prefix of @endforeach/@endforelse.
        result = regexReplace(result, pattern: #"@endfor(?!\w)"#, with: "")
        result = regexReplace(result, pattern: #"@while\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@endwhile"#, with: "")
        result = regexReplace(result, pattern: #"@forelse\s*"# + balancedParens, with: "")
        // @empty without parens (inside @forelse)
        result = regexReplace(result, pattern: #"@empty(?!\s*\()"#, with: "")
        result = regexReplace(result, pattern: #"@endforelse"#, with: "")
        result = regexReplace(result, pattern: #"@continue(?!\w)"#, with: "")

        // Auth directives
        result = regexReplace(result, pattern: #"(?<!\w)@auth(?:\s*"# + balancedParens + #")?"#, with: "")
        result = regexReplace(result, pattern: #"@endauth"#, with: "")
        result = regexReplace(result, pattern: #"@can\s*"# + balancedParens, with: "")
        // (?!\w) so @endcan doesn't eat the @endcan prefix of @endcanany.
        result = regexReplace(result, pattern: #"@endcan(?!\w)"#, with: "")
        result = regexReplace(result, pattern: #"@canany\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"@endcanany"#, with: "")

        // @error/@enderror: handled in Phase 1 (stripped WITH content) — see phase1_stripInvisible.
        // Any leftover (malformed/unterminated) @error(...) or stray @enderror falls to the
        // catch-all below, same as other directives with no dedicated block-level handling.

        // Catch-all: strip any remaining @directive(...) or @directive not already handled.
        // Negative lookbehind excludes email addresses (word char before @).
        // Negative lookahead excludes CSS at-rules (@font-face, @media, @keyframes, etc.)
        // that live inside inlined <style> blocks.
        let cssAtRules = #"(?!font|media|keyframes|import|charset|supports|layer|property|page|namespace|counter|container|scope|tailwind|apply)"#
        result = regexReplace(result, pattern: "(?<!\\w)@" + cssAtRules + #"[a-zA-Z]+\s*"# + balancedParens, with: "")
        result = regexReplace(result, pattern: #"(?<!\w)@end[a-zA-Z]+"#, with: "")
        result = regexReplace(result, pattern: "(?<!\\w)@" + cssAtRules + #"[a-zA-Z]+(?!\w)"#, with: "")

        return result
    }

    // MARK: - Loop expansion (fake-data repetition)

    /// How many times a @foreach/@forelse body repeats in the preview.
    static let loopRepeatCount = 3
    /// Only the outermost N loop levels expand (3^N growth guard).
    private static let maxLoopExpansionDepth = 2

    /// Repeats @foreach/@forelse bodies loopRepeatCount times so lists preview
    /// as populated tables. Copies 2..N get a "QBITER<n> " marker injected into
    /// their echoes so FakeData varies personas per row. @forelse keeps the
    /// loop branch and drops @empty (the preview simulates data being present,
    /// like the @auth handling in Phase 1). Runs after Phase 1 (verbatim and
    /// <style> blocks are already parked) and before Phase 2 (which strips the
    /// directives of any loop this pass left alone).
    private struct LoopKind {
        let open: String, close: String, hasEmptyDivider: Bool
        static let foreachKind = LoopKind(open: "foreach", close: "endforeach", hasEmptyDivider: false)
        static let forelseKind = LoopKind(open: "forelse", close: "endforelse", hasEmptyDivider: true)
    }

    private static func expandLoops(_ source: String, level: Int = 1) -> String {
        guard level <= maxLoopExpansionDepth else { return source }
        var result = source
        var searchLocation = 0
        var safety = 0
        while safety < 200 {
            safety += 1
            let ns = result as NSString
            guard searchLocation < ns.length else { break }
            let range = NSRange(location: searchLocation, length: ns.length - searchLocation)

            // Earliest opener of EITHER kind wins. Document order matters: two
            // sequential per-kind passes would let a @forelse nested deep inside
            // @foreach loops expand at level 1, breaking the depth cap.
            // (?<![\w@]) mirrors Blade's \B@ rule, like the @auth-family
            // patterns in Phase 1: a directive glued to a word character
            // (x@foreach) is literal text and must not expand — pinned by
            // testGluedForeachDoesNotExpand.
            var best: (kind: LoopKind, match: NSTextCheckingResult)? = nil
            for kind in [LoopKind.foreachKind, LoopKind.forelseKind] {
                guard let regex = cachedRegex(#"(?<![\w@])@"# + kind.open + #"\s*"# + balancedParens),
                      let m = regex.firstMatch(in: result, options: [], range: range)
                else { continue }
                if best == nil || m.range.location < best!.match.range.location {
                    best = (kind, m)
                }
            }
            guard let (kind, openMatch) = best else { break }

            let bodyStart = openMatch.range.location + openMatch.range.length
            guard let scanned = scanLoopBody(result, from: bodyStart, kind: kind) else {
                // Unterminated: skip this opener; Phase 2 strips the stray token.
                searchLocation = bodyStart
                continue
            }

            let full = NSRange(location: openMatch.range.location,
                               length: scanned.endOfClose - openMatch.range.location)
            guard let swiftRange = Range(full, in: result) else { break }

            // Preview doctrine: no validation errors (same stance as the @error strip in
            // Phase 1). A loop iterating an error-ish collection (`$errors`, `$messages`, …)
            // is dropped ENTIRELY — zero copies — rather than expanded, so fake row text
            // doesn't leak in under form fields.
            let openText = ns.substring(with: openMatch.range)
            if let parens = loopIterableParens(openText), iterableReferencesErrors(parens) {
                result.replaceSubrange(swiftRange, with: "")
                searchLocation = openMatch.range.location
                continue
            }

            // Inner loops expand within the body first, at the next level down.
            let body = expandLoops(scanned.body, level: level + 1)
            var copies = body
            for i in 1..<loopRepeatCount {
                copies += markEchoes(in: body, iteration: i)
            }
            result.replaceSubrange(swiftRange, with: copies)
            // Continue AFTER the replacement — the copies' own inner loops were
            // already handled (or deliberately capped) by the recursion above.
            searchLocation = openMatch.range.location + (copies as NSString).length
        }
        return result
    }

    /// Extracts the `(...)` argument text (without the wrapping parens) from a full loop-opener
    /// match like `@foreach((array) $messages as $message)`. The match is always exactly
    /// `@directive\s*(...)` with nothing trailing, so the first "(" and the LAST ")" in the
    /// text bound the argument list even though it may contain its own nested parens (e.g. a
    /// `(array)` cast or a `->all()` call).
    private static func loopIterableParens(_ openerText: String) -> String? {
        guard let firstParen = openerText.firstIndex(of: "("),
              let lastParen = openerText.lastIndex(of: ")"),
              firstParen < lastParen else { return nil }
        return String(openerText[openerText.index(after: firstParen)..<lastParen])
    }

    /// Trigger words for `iterableReferencesErrors`, matched as whole identifiers
    /// (case-insensitive), not substrings — a small, local, minimal approximation (FakeData's
    /// `identifierSegments` classifier does similar word-splitting but is `private` to that
    /// type and not cleanly reusable here).
    private static let errorIterableWords: Set<String> = ["error", "errors", "messages"]

    /// True if the loop's ITERABLE expression — the part of the parens content BEFORE `as` —
    /// references an error-ish identifier (`$errors`, `$messages`, `(array) $messages`, …).
    /// Checked ONLY against the iterable, never the loop VARIABLE: `@foreach($items as
    /// $message)` must still expand even though its loop variable happens to be named
    /// `$message` — only `@foreach($messages as $message)`-style iterables (identifier before
    /// `as`) trigger the drop.
    private static func iterableReferencesErrors(_ parensContent: String) -> Bool {
        let iterablePart: String
        if let asRange = parensContent.range(of: #"\bas\b"#, options: .regularExpression) {
            iterablePart = String(parensContent[parensContent.startIndex..<asRange.lowerBound])
        } else {
            iterablePart = parensContent
        }
        guard let regex = cachedRegex(#"\$([A-Za-z_][A-Za-z0-9_]*)"#) else { return false }
        let ns = iterablePart as NSString
        let matches = regex.matches(in: iterablePart, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if errorIterableWords.contains(ns.substring(with: m.range(at: 1)).lowercased()) {
                return true
            }
        }
        return false
    }

    /// Finds the matching close directive for a loop opener, counting nested
    /// SAME-kind openers (each kind has a distinct close token, so other kinds
    /// don't affect pairing). For @forelse, also finds the top-level bare
    /// @empty divider — the parenthesized @empty(...) form is a different
    /// directive and is excluded. Returns the kept body (first branch for
    /// @forelse) and the index just past the closing directive.
    /// Group numbering is fixed: 1 = opener, 2 = bare @empty, 3 = close.
    /// A bare @empty seen while scanning a @foreach (hasEmptyDivider false)
    /// belongs to some nested @forelse and is ignored here.
    private static func scanLoopBody(
        _ source: String, from start: Int, kind: LoopKind
    ) -> (body: String, endOfClose: Int)? {
        // (?<![\w@]) mirrors Blade's \B@ rule (see expandLoops) — glued
        // tokens are literal text, not directives.
        let tokenPattern = #"(?<![\w@])@(?:("# + kind.open + #")\s*"# + balancedParens +
            #"|(empty)(?!\s*\()|("# + kind.close + #")(?!\w))"#
        guard let tokenRegex = cachedRegex(tokenPattern) else { return nil }
        let ns = source as NSString
        var depth = 0
        var dividerStart: Int? = nil
        var cursor = start
        while cursor < ns.length {
            guard let m = tokenRegex.firstMatch(
                in: source, options: [],
                range: NSRange(location: cursor, length: ns.length - cursor))
            else { return nil }
            if m.range(at: 1).location != NSNotFound {
                depth += 1                                    // nested same-kind opener
            } else if m.range(at: 2).location != NSNotFound {
                if kind.hasEmptyDivider && depth == 0 && dividerStart == nil {
                    dividerStart = m.range.location           // top-level @empty divider
                }
            } else {
                if depth == 0 {
                    let bodyEnd = dividerStart ?? m.range.location
                    let body = ns.substring(
                        with: NSRange(location: start, length: bodyEnd - start))
                    return (body, m.range.location + m.range.length)
                }
                depth -= 1
            }
            cursor = m.range.location + m.range.length
        }
        return nil
    }

    /// Prefixes every echo in a repeated loop-body copy with the iteration
    /// marker FakeData reads. The (?<!@) lookbehind protects @{{ }} escapes
    /// (their braces must reach Phase 3 untouched to be restored as literals).
    private static func markEchoes(in body: String, iteration: Int) -> String {
        var result = body
        result = regexReplace(result, pattern: #"(?<!@)\{\{"#, with: "{{ QBITER\(iteration) ")
        result = regexReplace(result, pattern: #"(?<!@)\{!!"#, with: "{!! QBITER\(iteration) ")
        return result
    }

    // MARK: - Phase 3: Replace variables (order matters!)
    //
    // Variables inside HTML attributes (e.g. href="{{ route('login') }}")
    // can't use <span> tags — that would break the HTML parser.
    //
    // Strategy: Replace ALL variables with inert placeholders first, then
    // expand each placeholder to either plain text (inside attributes) or
    // a styled <span> (in body text). This avoids the problem where
    // expressions like $user->name contain ">" which breaks tag-matching.

    private static func phase3_replaceVariables(_ source: String) -> String {
        var result = source

        // 0. FontAwesome weight is often picked by a Blade ternary inside class="…", e.g.
        //    {{ request()->routeIs('x') ? 'fas' : 'far' }}. Otherwise the steps below would
        //    replace the whole echo with an inert "#" (it sits inside the <i> tag), dropping the
        //    fa-weight class — so the icon font never applies and the glyph disappears. A static
        //    preview shows the inactive state, so resolve such ternaries to their else-branch weight.
        let faWeight = #"(?:fa[srlbtd]{0,2}|fa-(?:solid|regular|light|thin|duotone|brands))"#
        result = regexReplaceWithCapture(result,
            pattern: #"\{\{[^{}]*?\?\s*['"]"# + faWeight + #"['"]\s*:\s*['"]("# + faWeight + #")['"][^{}]*?\}\}"#,
            template: "$1")

        // Generic literal ternary: {{ cond ? '+' : '-' }} → "+". The preview
        // simulates the positive/true state (same stance as @auth handling).
        // Runs AFTER the FA-weight rule, which deliberately keeps its ELSE branch.
        // [^{}?] before the `?` keeps a `??` null-coalesce from half-matching
        // as a ternary (see testNullCoalesceIsNotATernary).
        result = regexReplaceWithCapture(result,
            pattern: #"\{\{[^{}?]*\?\s*'([^']*)'\s*:\s*'[^']*'\s*\}\}"#,
            template: "$1")
        result = regexReplaceWithCapture(result,
            pattern: #"\{\{[^{}?]*\?\s*"([^"]*)"\s*:\s*"[^"]*"\s*\}\}"#,
            template: "$1")

        // 1. @{{ }} — Vue/Alpine escaped syntax. The author wants the LITERAL {{ }} to
        //    survive into the preview, so park it in a placeholder the variable collectors
        //    below won't match, then restore it after expansion (step 6).
        var substitutions: [String: String] = [:]
        if let escapedRegex = cachedRegex(#"@\{\{([\s\S]*?)\}\}"#) {
            var n = 0
            result = rewriteMatches(result, escapedRegex) { match, ns in
                let expr = match.range(at: 1).location == NSNotFound
                    ? "" : ns.substring(with: match.range(at: 1))
                let id = "QUICKBLADE_LITERAL_\(n)_"
                n += 1
                substitutions[id] = "{{\(expr)}}"
                return id
            }
        }

        // 2. Resolve translation calls, with or without replacement args:
        //    {{ __('Text') }} / {{ __('Hi :name', [...]) }} → Text
        result = regexReplaceWithCapture(result,
            pattern: #"\{\{\s*(?:QBITER\d+\s+)?__\(\s*'([^']*)'\s*(?:,[\s\S]*?)?\)\s*\}\}"#,
            template: "$1")
        result = regexReplaceWithCapture(result,
            pattern: #"\{\{\s*(?:QBITER\d+\s+)?__\(\s*"([^"]*)"\s*(?:,[\s\S]*?)?\)\s*\}\}"#,
            template: "$1")

        // 3. Collect remaining variables and replace with placeholders
        var placeholders: [(id: String, expr: String, isRaw: Bool)] = []
        var counter = 0

        // {!! expr !!} first (raw), then {{ expr }} — [\s\S] so multiline echoes match.
        for (pattern, isRaw) in [(#"\{!!\s*([\s\S]*?)\s*!!\}"#, true), (#"\{\{\s*([\s\S]*?)\s*\}\}"#, false)] {
            guard let regex = cachedRegex(pattern) else { continue }
            result = rewriteMatches(result, regex) { match, ns in
                let expr = match.range(at: 1).location == NSNotFound
                    ? "" : ns.substring(with: match.range(at: 1))
                let id = "QUICKBLADE_VAR_\(counter)_"
                counter += 1
                placeholders.append((id: id, expr: expr, isRaw: isRaw))
                return id
            }
        }

        // 4. Classify each placeholder's position (body / quoted attr / bare in tag)
        let contexts = placeholderContexts(result, placeholders: placeholders)

        // 5. Decide each placeholder's replacement: body text and visible-text
        //    attributes get deterministic fake values; URL-ish attributes keep an
        //    inert "#" (img src gets a neutral SVG placeholder); everything else
        //    stays empty. Nothing is written to the document yet — one pass in
        //    step 7 applies them all.
        var imgSrcIDs = Set<String>()
        for ph in placeholders {
            switch contexts[ph.id] ?? .body {
            case .body:
                substitutions[ph.id] = FakeData.value(for: ph.expr)
            case .tagUnquoted:
                substitutions[ph.id] = "#"
            case .quotedAttr(let name, let tag):
                if fakeValueAttrs.contains(name) {
                    substitutions[ph.id] = FakeData.value(for: ph.expr)
                } else if name == "src", tag == "img" {
                    // The echo may be only PART of the src value (e.g. a literal
                    // CDN prefix + a dynamic path segment) — gluing the data URI
                    // onto that prefix produces a broken URL. Step 6 replaces the
                    // WHOLE quoted attribute value instead of just this placeholder.
                    imgSrcIDs.insert(ph.id)
                    // Fallback if that pass somehow doesn't cover it, so a raw
                    // placeholder id can never reach the rendered output.
                    substitutions[ph.id] = imagePlaceholderDataURI
                } else if hashAttrs.contains(name) {
                    substitutions[ph.id] = "#"
                } else {
                    substitutions[ph.id] = ""
                }
            }
        }

        // 6. Swap whole `src="…"` values that contain a dynamic echo. One pass over
        //    the document for all of them, rather than one pass per placeholder.
        if !imgSrcIDs.isEmpty {
            result = replaceImgSrcValues(result, containingAnyOf: imgSrcIDs)
        }

        // 7. Apply every placeholder and parked literal in a single scan. Doing this
        //    per-placeholder (a full-document `replacingOccurrences` each) was the
        //    dominant cost in this phase — 254KB of ordinary markup took 24s.
        if let tokenRegex = cachedRegex(placeholderTokenPattern) {
            result = rewriteMatches(result, tokenRegex) { match, ns in
                let id = ns.substring(with: match.range)
                // An unknown token isn't ours to consume — leave it verbatim.
                return substitutions[id] ?? id
            }
        }

        return result
    }

    /// Matches any placeholder this phase parks: `QUICKBLADE_VAR_12_`,
    /// `QUICKBLADE_LITERAL_3_`. The trailing `_` is load-bearing — it stops
    /// `..._1_` matching inside `..._10_`.
    private static let placeholderTokenPattern = #"QUICKBLADE_(?:VAR|LITERAL)_\d+_"#

    /// Rebuilds `source` with each match replaced by `replacement(...)`, in ONE
    /// forward pass. The obvious alternative — mutating the string per match — is
    /// O(document) per edit, so a document with thousands of echoes went quadratic.
    private static func rewriteMatches(
        _ source: String,
        _ regex: NSRegularExpression,
        _ replacement: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let ns = source as NSString
        let matches = regex.matches(in: source, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return source }

        var out = ""
        out.reserveCapacity(source.utf8.count)
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            out += replacement(match, ns)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out += ns.substring(from: cursor)
        }
        return out
    }

    private enum PlaceholderContext {
        case body                                  // outside any tag → fake value
        case tagUnquoted                           // inside a tag, not in a quoted attr → "#"
        case quotedAttr(name: String, tag: String) // inside a quoted attr of <tag …>
    }

    /// Attributes whose value is a URL target where "" would be misleading;
    /// these keep the inert "#" (an img src gets a neutral SVG placeholder
    /// instead — see imagePlaceholderDataURI). fakeValueAttrs takes
    /// precedence over this set. Everything else becomes an empty string.
    private static let hashAttrs: Set<String> = [
        "href", "src", "srcset", "action", "formaction", "poster", "data", "xlink:href",
    ]

    /// Attributes whose value is user-visible text — these show the same fake
    /// value the body context would (a form previews as filled in).
    private static let fakeValueAttrs: Set<String> = ["value", "placeholder", "alt", "title"]

    /// Neutral gray rounded rectangle shown for dynamic <img src> echoes,
    /// instead of the broken-image icon "#" produced.
    static let imagePlaceholderDataURI =
        "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='400' height='300'%3E%3Crect width='400' height='300' rx='8' fill='%23e4e4e7'/%3E%3C/svg%3E"

    /// Replaces the ENTIRE quoted `src="..."` value wherever it contains one of
    /// `ids`, instead of substituting only the placeholder text in place.
    /// A dynamic `<img src>` echo can sit after a literal prefix (e.g. a CDN
    /// base URL) — substituting only the placeholder would glue the data URI
    /// onto that prefix and produce a broken src. Handles both quote styles.
    ///
    /// One pass for ALL ids: the per-id version compiled a regex containing the id
    /// and scanned the whole document once per dynamic image, which was both
    /// quadratic and an unbounded source of one-shot cache entries.
    private static func replaceImgSrcValues(_ source: String, containingAnyOf ids: Set<String>) -> String {
        guard let regex = cachedRegex(#"src\s*=\s*(?:"[^"]*+"|'[^']*+')"#),
              let tokenRegex = cachedRegex(placeholderTokenPattern) else { return source }
        return rewriteMatches(source, regex) { match, ns in
            let whole = ns.substring(with: match.range)
            let wholeNS = whole as NSString
            // Pull the token out of the value and look it up, rather than testing
            // every known id against the value — that was O(images) per image.
            let hit = tokenRegex
                .matches(in: whole, options: [],
                         range: NSRange(location: 0, length: wholeNS.length))
                .contains { ids.contains(wholeNS.substring(with: $0.range)) }
            return hit ? "src=\"\(imagePlaceholderDataURI)\"" : whole
        }
    }

    /// Classifies where each QUICKBLADE_VAR_N placeholder sits.
    ///
    /// Scans each tag for the placeholder tokens it actually contains, rather than
    /// testing every known placeholder against every tag — that cross product was
    /// O(tags x echoes) and dominated large pages.
    private static func placeholderContexts(
        _ source: String,
        placeholders: [(id: String, expr: String, isRaw: Bool)]
    ) -> [String: PlaceholderContext] {
        guard !placeholders.isEmpty,
              let tagRegex = cachedRegex(#"<[a-zA-Z][^>]*>"#),
              let tokenRegex = cachedRegex(placeholderTokenPattern),
              let attrRegex = cachedRegex(#"([\w:.\-]+)\s*=\s*(?:"[^"]*+"|'[^']*+')"#)
        else { return [:] }

        var contexts: [String: PlaceholderContext] = [:]
        let ns = source as NSString
        tagRegex.enumerateMatches(
            in: source, options: [], range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match = match else { return }
            let tag = ns.substring(with: match.range)
            let tagNS = tag as NSString
            let tagRange = NSRange(location: 0, length: tagNS.length)

            let tokens = tokenRegex.matches(in: tag, options: [], range: tagRange)
            guard !tokens.isEmpty else { return }

            let tagName = String(tag.dropFirst().prefix { $0.isLetter || $0.isNumber }).lowercased()
            // Attribute spans in this tag, resolved once and shared by its tokens.
            let attrs = attrRegex.matches(in: tag, options: [], range: tagRange).map {
                (name: tagNS.substring(with: $0.range(at: 1)).lowercased(), range: $0.range)
            }

            for token in tokens {
                let id = tagNS.substring(with: token.range)
                let owner = attrs.first {
                    token.range.location >= $0.range.location
                        && token.range.location < $0.range.location + $0.range.length
                }
                contexts[id] = owner.map { .quotedAttr(name: $0.name, tag: tagName) } ?? .tagUnquoted
            }
        }
        return contexts
    }

    // MARK: - Phase 4: Strip includes and components

    private static func phase4_replaceIncludes(_ source: String) -> String {
        var result = source

        // Strip any remaining @include directives (those not resolved by TemplateResolver)
        result = regexReplace(result, pattern: #"@include\s*\(\s*['"][^'"]*['"](?:\s*,\s*[^)]*)?\)"#, with: "")
        result = regexReplace(result, pattern: #"@includeIf\s*\(\s*['"][^'"]*['"][^)]*\)"#, with: "")
        result = regexReplace(result, pattern: #"@includeWhen\s*\([^,]*,\s*['"][^'"]*['"][^)]*\)"#, with: "")
        result = regexReplace(result, pattern: #"@includeUnless\s*\([^,]*,\s*['"][^'"]*['"][^)]*\)"#, with: "")
        result = regexReplace(result, pattern: #"@includeIsolated\s*\(\s*['"][^'"]*['"][^)]*\)"#, with: "")
        result = regexReplace(result, pattern: #"@includeFirst\s*\(\s*\[[^\]]*\][^)]*\)"#, with: "")
        result = regexReplace(result, pattern: #"@each\s*\(\s*['"][^'"]*['"][^)]*\)"#, with: "")

        // Quote-aware attribute matching: handles > inside quoted values (e.g. request()->routeIs()).
        // Possessive (++) on the unquoted run prevents catastrophic backtracking on an unclosed tag.
        let quotedAttrs = attrRun

        // Self-closing component tags: <x-name /> → strip entirely
        result = regexReplace(result, pattern: "<x-[\\w\\-\\.:]+(?:\\s" + quotedAttrs + ")?\\s*/>", with: "")

        // Opening/closing component tags: <x-name>...</x-name> → keep inner content
        result = regexReplace(result, pattern: #"</x-[\w\-\.:]+>"#, with: "")
        result = regexReplace(result, pattern: "<x-[\\w\\-\\.:]+(?:\\s" + quotedAttrs + ")?\\s*>", with: "")

        // Slots: strip <x-slot> tags
        result = regexReplace(result, pattern: "<x-slot\\s" + quotedAttrs + ">", with: "")
        result = regexReplace(result, pattern: #"</x-slot>"#, with: "")

        return result
    }

    // MARK: - Phase 5: Clean whitespace

    private static func phase5_cleanWhitespace(_ source: String) -> String {
        // Collapse 3+ consecutive newlines to 2
        return regexReplace(source, pattern: #"\n{3,}"#, with: "\n\n")
    }

    // MARK: - Flux / Livewire component expansion

    /// Attribute run inside a tag. Possessive AND length-bounded on the quoted values —
    /// see the long note on `TemplateResolver.quotedAttrRun` for why both matter on
    /// untrusted input (an unterminated quote otherwise costs ~10s per pass on a
    /// 315KB file). 8192 is far above any real attribute value.
    static let attrRun = #"(?:[^>"']++|"[^"]{0,8192}+"|'[^']{0,8192}+')*"#

    // Quote-aware attribute run. `/` is excluded from the unquoted alternative so a trailing
    // `/>` is never swallowed; same possessive + bounded guards as attrRun.
    private static let fluxAttrs = #"((?:[^>"'/]++|"[^"]{0,8192}+"|'[^']{0,8192}+')*)"#

    /// Rewrites `<flux:*>` / `<livewire:*>` tags into native HTML. See transpile() for why.
    private static func expandNamespacedComponents(_ source: String) -> String {
        var result = source

        // Livewire nested components have no static markup — self-closing get removed,
        // paired get unwrapped (inner content, if any, is kept).
        result = regexReplace(result, pattern: #"<livewire:[\w\-.:]+"# + fluxAttrs + #"\s*/>"#, with: "")
        result = regexReplace(result, pattern: #"</livewire:[\w\-.:]+>"#, with: "")
        result = regexReplace(result, pattern: #"<livewire:[\w\-.:]+"# + fluxAttrs + #">"#, with: "")

        // Flux self-closing first (so `<flux:x ... />` isn't mistaken for an unclosed open tag).
        result = regexReplaceWithBlock(result, pattern: #"<flux:([\w\-.:]+)"# + fluxAttrs + #"\s*/>"#) { caps in
            fluxSelfClosing(name: caps[1], attrs: caps.count > 2 ? caps[2] : "")
        }
        // Flux closing tags → native close.
        result = regexReplaceWithBlock(result, pattern: #"</flux:([\w\-.:]+)>"#) { caps in
            "</\(fluxElement(caps[1]).tag)>"
        }
        // Flux opening (paired) tags → native open with data hooks + preserved class.
        result = regexReplaceWithBlock(result, pattern: #"<flux:([\w\-.:]+)"# + fluxAttrs + #">"#) { caps in
            fluxOpenTag(name: caps[1], attrs: caps.count > 2 ? caps[2] : "")
        }

        return result
    }

    /// Maps a Flux component name (possibly dotted, e.g. `table.cell`) to a native element and
    /// the `data-flux-*` hook the shim stylesheet keys off. Must be deterministic per name so
    /// independently-rewritten opening and closing tags stay balanced.
    private static func fluxElement(_ rawName: String) -> (tag: String, attr: String) {
        switch rawName.lowercased() {
        case "card": return ("div", "data-flux-card")
        case "heading": return ("div", "data-flux-heading")
        case "subheading": return ("div", "data-flux-subheading")
        case "text", "callout.text": return ("p", "data-flux-text")
        case "callout": return ("div", "data-flux-callout")
        case "callout.heading": return ("div", "data-flux-callout-heading")
        case "field": return ("div", "data-flux-field")
        case "fieldset": return ("fieldset", "data-flux-field")
        case "label": return ("label", "data-flux-label")
        case "description": return ("div", "data-flux-description")
        case "error": return ("div", "data-flux-error")
        case "badge": return ("span", "data-flux-badge")
        case "button": return ("button", "data-flux-button")
        case "link", "breadcrumbs.item":
            return ("a", "data-flux-link")
        // Nav items get their own hooks so the app-shell shim can style sidebar entries as
        // full-width vertical rows and header/footer entries as inline icon buttons — distinct
        // from a plain inline text <flux:link>.
        case "sidebar.item": return ("a", "data-flux-sidebar-item")
        case "navbar.item", "navlist.item": return ("a", "data-flux-navbar-item")
        case "sidebar.header": return ("div", "data-flux-sidebar-header")
        case "sidebar.nav", "sidebar.group": return ("nav", "data-flux-sidebar-nav")
        case "sidebar.brand": return ("a", "data-flux-sidebar-brand")
        case "select": return ("select", "data-flux-input")
        case "select.option": return ("option", "")
        case "textarea": return ("textarea", "data-flux-input")
        case "tooltip": return ("span", "")
        case "modal": return ("div", "data-flux-modal")
        case "menu": return ("div", "data-flux-menu")
        case "menu.item", "menu.radio", "menu.checkbox": return ("div", "data-flux-menu-item")
        case "tabs": return ("div", "data-flux-tabs")
        case "tab": return ("button", "data-flux-tab")
        case "tab.panel": return ("div", "")
        case "navbar", "navlist", "breadcrumbs": return ("nav", "data-flux-navbar")
        case "sidebar": return ("aside", "data-flux-sidebar")
        case "header": return ("header", "data-flux-header")
        case "footer": return ("footer", "data-flux-footer")
        case "main": return ("main", "data-flux-main")
        case "table": return ("table", "data-flux-table")
        case "table.columns": return ("thead", "")
        case "table.column": return ("th", "")
        case "table.rows": return ("tbody", "")
        case "table.row": return ("tr", "")
        case "table.cell": return ("td", "")
        case "avatar": return ("span", "data-flux-avatar")
        case "separator": return ("div", "data-flux-separator")
        default: return ("div", "data-flux-generic")
        }
    }

    private static func fluxOpenTag(name: String, attrs: String) -> String {
        let el = fluxElement(name)
        var out = "<\(el.tag)"
        if !el.attr.isEmpty { out += " \(el.attr)" }
        if let v = attrValue("size", in: attrs) { out += " data-flux-size=\"\(v)\"" }
        if let v = attrValue("variant", in: attrs) { out += " data-flux-variant=\"\(v)\"" }
        if let v = attrValue("color", in: attrs) { out += " data-flux-color=\"\(v)\"" }
        if let cls = attrValue("class", in: attrs) {
            let cleaned = cleanClassValue(cls)
            if !cleaned.isEmpty { out += " class=\"\(cleaned)\"" }
        }
        return out + ">"
    }

    private static func fluxSelfClosing(name: String, attrs: String) -> String {
        let lower = name.lowercased()
        // Icons have no offline SVG to inline — drop them rather than leak empty boxes.
        if lower == "icon" || lower.hasPrefix("icon.") || lower.hasSuffix(".logo") { return "" }

        // Several Flux controls carry their visible text in `label`/`description`/`placeholder`
        // attributes (not slots). Keep those as content so the control isn't a textless stub.
        // `{{ }}`/`{!! !!}` are left intact so Phase 3 resolves __() and drops runtime vars.
        func nonEmpty(_ v: String?) -> String? {
            guard let v = v, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }
        let label = nonEmpty(attrValue("label", in: attrs))
        let desc = nonEmpty(attrValue("description", in: attrs))
        let labelHTML = label.map { "<label data-flux-label>\($0)</label>" } ?? ""
        let descHTML = desc.map { "<div data-flux-description>\($0)</div>" } ?? ""
        let cls = attrValue("class", in: attrs).map(cleanClassValue).flatMap { $0.isEmpty ? nil : $0 }
        let classAttr = cls.map { " class=\"\($0)\"" } ?? ""

        switch lower {
        case "switch":
            let toggle = "<span data-flux-switch></span>"
            return (label != nil || desc != nil)
                ? "<div data-flux-control-row><div>\(labelHTML)\(descHTML)</div>\(toggle)</div>"
                : toggle
        case "checkbox", "radio":
            let box = "<input type=\"\(lower)\" data-flux-\(lower)>"
            return (label != nil || desc != nil)
                ? "<div data-flux-control-row>\(box)<div>\(labelHTML)\(descHTML)</div></div>"
                : box
        case "input", "textarea", "select":
            let control: String
            switch lower {
            case "textarea": control = "<textarea data-flux-input\(classAttr)></textarea>"
            case "select": control = "<select data-flux-input\(classAttr)></select>"
            default:
                let ph = attrValue("placeholder", in: attrs).map(cleanClassValue).flatMap { $0.isEmpty ? nil : $0 }
                let phAttr = ph.map { " placeholder=\"\($0)\"" } ?? ""
                control = "<input data-flux-input\(phAttr)\(classAttr)>"
            }
            return (label != nil || desc != nil)
                ? "<div data-flux-field>\(labelHTML)\(control)\(descHTML)</div>"
                : control
        case "separator":
            return "<hr data-flux-separator>"
        case "spacer":
            return "<div data-flux-spacer></div>"
        case "avatar":
            return "<span data-flux-avatar></span>"
        default:
            let el = fluxElement(name)
            // Unknown self-closing components carry no content — drop them entirely.
            if el.attr == "data-flux-generic" { return "" }
            return "<\(el.tag) \(el.attr)\(classAttr)></\(el.tag)>"
        }
    }

    /// Reads a static attribute value (double- or single-quoted). The lookbehind rejects
    /// dynamic bindings like `:class`/`wire:size` so we don't pull PHP expressions into output.
    private static func attrValue(_ name: String, in attrs: String) -> String? {
        for quote in ["\"([^\"]*)\"", "'([^']*)'"] {
            guard let r = cachedRegex("(?<![\\w:.\\-])" + name + #"\s*=\s*"# + quote) else { continue }
            let range = NSRange(attrs.startIndex..., in: attrs)
            if let m = r.firstMatch(in: attrs, options: [], range: range),
               let rng = Range(m.range(at: 1), in: attrs) {
                return String(attrs[rng])
            }
        }
        return nil
    }

    /// Strips Blade expressions out of a class string so leftovers like `{{ $x }}` don't
    /// become junk class tokens, then normalizes whitespace.
    private static func cleanClassValue(_ value: String) -> String {
        var v = value
        v = regexReplace(v, pattern: #"\{\{.*?\}\}"#, with: "")
        v = regexReplace(v, pattern: #"\{!!.*?!!\}"#, with: "")
        v = regexReplace(v, pattern: #"\s+"#, with: " ")
        return v.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Branch-aware conditional resolution

    // Tokenizes the conditional directives relevant to branch scanning.
    // Group 1: openers that REQUIRE (...) — a bare `@empty` (the @forelse divider)
    //          or a malformed `@if` with no parens is deliberately not a token.
    // Group 2: openers with OPTIONAL (...) (@auth / @guest guards).
    // Group 3: dividers and closers (never consume parens, so prose in
    //          parentheses after e.g. @endguest is not swallowed).
    // (?<![\w@])@ mirrors Blade's own `\B@` compiler rule: a directive's @ must
    // not be preceded by a word character — Laravel itself treats `sales@auth.io`
    // or a glued `@endif@else` as literal text, not directives. The @ exclusion
    // covers the parked `@@` escape.
    private static let conditionalTokenPattern =
        #"(?<![\w@])@(?:(if|unless|isset|empty|session|canany|cannot|can|error)\s*"# + balancedParens +
        #"|(auth|guest|admin)\b(?:\s*\([^)]*\))?"# +
        #"|(elseif|else|endif|endunless|endisset|endempty|endsession|endcanany|endcannot|endcan|endauth|endguest|endadmin|enderror)\b)"#

    /// Resolves a `@open … [@else …] @close` block to ONE branch. Counts nested
    /// conditional directives so an inner @if's @else isn't mistaken for the
    /// block's own. `openPattern` must match the opening directive including any
    /// (...) argument. Unterminated blocks are left untouched (Phase 2's
    /// catch-all still strips the stray tokens).
    private static func resolveBranchDirective(
        _ source: String,
        openPattern: String,
        closeToken: String,
        keepFirstBranch: Bool
    ) -> String {
        guard let openRegex = cachedRegex(openPattern) else { return source }
        var result = source
        var searchLocation = 0
        var safety = 0
        while safety < 100 {
            safety += 1
            let ns = result as NSString
            guard searchLocation < ns.length,
                  let open = openRegex.firstMatch(
                    in: result, options: [],
                    range: NSRange(location: searchLocation, length: ns.length - searchLocation)
                  ) else { break }
            let bodyStart = open.range.location + open.range.length
            guard let parsed = scanConditionalBody(result, from: bodyStart, closeToken: closeToken) else {
                // Unterminated block: skip past this opener and keep scanning —
                // later well-formed blocks of the same type must still resolve.
                // Phase 2's catch-all strips any stray tokens left behind.
                searchLocation = bodyStart
                continue
            }
            let kept = keepFirstBranch ? parsed.firstBranch : (parsed.elseBranch ?? "")
            let full = NSRange(location: open.range.location,
                               length: parsed.endOfClose - open.range.location)
            guard let swiftRange = Range(full, in: result) else { break }
            result.replaceSubrange(swiftRange, with: kept)
            // Rescan from the replacement point: the kept branch may contain
            // nested same-type blocks that are now top-level.
            searchLocation = open.range.location
        }
        return result
    }

    /// Scans from `start` for the block's top-level @else and its `closeToken`,
    /// tracking nesting depth of other conditional blocks along the way.
    private static func scanConditionalBody(
        _ source: String, from start: Int, closeToken: String
    ) -> (firstBranch: String, elseBranch: String?, endOfClose: Int)? {
        guard let tokenRegex = cachedRegex(conditionalTokenPattern) else { return nil }
        let ns = source as NSString
        var depth = 0
        var elseTokenStart: Int? = nil
        var elseTokenEnd = 0
        var cursor = start
        while cursor < ns.length {
            guard let m = tokenRegex.firstMatch(
                in: source, options: [], range: NSRange(location: cursor, length: ns.length - cursor)
            ) else { return nil }

            let token: String
            let isOpener: Bool
            if m.range(at: 1).location != NSNotFound {
                token = ns.substring(with: m.range(at: 1)); isOpener = true
            } else if m.range(at: 2).location != NSNotFound {
                token = ns.substring(with: m.range(at: 2)); isOpener = true
            } else {
                token = ns.substring(with: m.range(at: 3)); isOpener = false
            }

            if depth == 0 && token == closeToken {
                let firstEnd = elseTokenStart ?? m.range.location
                let first = ns.substring(with: NSRange(location: start, length: firstEnd - start))
                var elseBranch: String? = nil
                if elseTokenStart != nil {
                    elseBranch = ns.substring(
                        with: NSRange(location: elseTokenEnd, length: m.range.location - elseTokenEnd))
                }
                return (first, elseBranch, m.range.location + m.range.length)
            }

            if isOpener {
                depth += 1
            } else if token == "else" {
                if depth == 0 && elseTokenStart == nil {
                    elseTokenStart = m.range.location
                    elseTokenEnd = m.range.location + m.range.length
                }
            } else if token != "elseif" {
                // some @end… that isn't our closeToken
                depth = max(0, depth - 1)
            }
            cursor = m.range.location + m.range.length
        }
        return nil
    }

    // MARK: - Regex helpers

    // Guarded by regexCacheLock — Quick Look's concurrency behavior across
    // preview requests is undocumented, so assume cachedRegex can race.
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        regexCache[pattern] = regex
        return regex
    }

    private static func regexReplace(_ source: String, pattern: String, with replacement: String) -> String {
        guard let regex = cachedRegex(pattern) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: replacement)
    }

    private static func regexReplaceWithCapture(_ source: String, pattern: String, template: String) -> String {
        guard let regex = cachedRegex(pattern) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: template)
    }

    /// Replaces matches using a closure that receives the captured groups (index 0 = full match).
    /// Processes matches in reverse so earlier ranges stay valid as the string is mutated.
    private static func regexReplaceWithBlock(_ source: String, pattern: String, transform: (_ captures: [String]) -> String) -> String {
        guard let regex = cachedRegex(pattern) else { return source }
        let ns = source as NSString
        let matches = regex.matches(in: source, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return source }

        var result = source
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            var captures: [String] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                captures.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result.replaceSubrange(fullRange, with: transform(captures))
        }
        return result
    }
}
