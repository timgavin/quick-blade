import Foundation
import os.log
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.quickblade.BladeQuickLook", category: "resolver")

struct TemplateResolver {

    /// Why a preview degraded, for the user-facing diagnostics strip.
    /// Reference type so the deeply-static resolver can thread one instance
    /// through its helpers without changing every return type.
    final class Diagnostics {
        var readDenied = false     // an existing file could not be read (permission)
        var layoutMissing = false  // @extends names a view that doesn't exist
        var hasIssue: Bool { readDenied || layoutMissing }
    }

    struct Result {
        let html: String
        let didResolveLayout: Bool
        let didInlineCSS: Bool
        let diagnostics: Diagnostics
    }

    // Balanced parentheses (3 levels) — reused for @vite() matching.
    // Possessive (++) on the non-paren runs prevents catastrophic backtracking on unbalanced input.
    private static let balancedParens = #"\((?:[^()]++|\((?:[^()]++|\([^()]*\))*\))*\)"#

    /// The attribute run inside a `<x-…>` tag: unquoted text, or a quoted value (which
    /// is allowed to contain `>`, e.g. `:active="request()->routeIs('x')"`).
    ///
    /// Two guards, both load-bearing on untrusted input:
    /// * Possessive (`++`, `*+`) — no backtracking. Safe because `[^"]` can't match `"`,
    ///   so the greedy run already stops at the next quote and giving characters back
    ///   could never let the closing quote match.
    /// * The quoted values are LENGTH-BOUNDED. Possessive alone isn't enough: an
    ///   unterminated quote still made every `<x-` start position rescan the whole
    ///   remaining document, so 3,000 `<x-a ` tags before one stray `"` cost 10s per
    ///   pass. The bound caps that rescan instead. 8192 is far above any real attribute
    ///   value (a 2,400-character Tailwind class list matches identically), and a value
    ///   longer than the bound only means the tag isn't recognised — never mis-parsed.
    private static let quotedAttrRun = #"(?:[^>"']++|"[^"]{0,8192}+"|'[^']{0,8192}+')*"#

    /// `quotedAttrRun` with `/` excluded from the unquoted alternative, for matching a
    /// self-closing `… />` — see the note in resolveComponents.
    private static let selfClosingAttrRun = #"(?:[^>"'/]++|"[^"]{0,8192}+"|'[^']{0,8192}+')*"#

    // MARK: - Public API

    static func resolve(source: String, fileURL: URL) -> Result {
        let diag = Diagnostics()
        guard let projectRoot = findLaravelRoot(from: fileURL) else {
            logger.info("No Laravel project root found")
            // Distinguish "genuinely not a Laravel project" (silent fallback)
            // from "the sandbox/TCC can't even list the file's siblings".
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                   && error.code == NSFileReadNoPermissionError {
                diag.readDenied = true
                logger.error("Parent directory unreadable (permission) — flagging readDenied")
            } catch {
                // Other listing errors (volume gone, etc.) aren't the TCC story.
            }
            return Result(html: source, didResolveLayout: false, didInlineCSS: false,
                          diagnostics: diag)
        }
        logger.info("Laravel root: \(projectRoot.path)")

        // Try component-based layout, then extends-based layout, then a Livewire full-page
        // view's class-attached layout (invisible in the .blade file — see resolveLivewireLayout).
        let composed = resolveComponentLayout(source: source, projectRoot: projectRoot, diag: diag)
            ?? resolveExtendsLayout(source: source, projectRoot: projectRoot, diag: diag)
            ?? resolveLivewireLayout(source: source, fileURL: fileURL, projectRoot: projectRoot, diag: diag)

        guard let composed else {
            // No layout determinable — e.g. a Livewire nested component (not a full page) or a
            // bare partial. Render the page's own content styled with the app's real compiled CSS.
            logger.info("No layout directive found; rendering bare page with project CSS")
            return wrapBarePage(content: source, projectRoot: projectRoot, diag: diag)
        }

        return postProcess(composed: composed, projectRoot: projectRoot, diag: diag)
    }

    /// Builds a self-contained HTML document for a page that declares no layout, inlining the
    /// project's compiled CSS so Tailwind/Flux utility classes actually apply. Mirrors the
    /// asset-inlining the layout path does, minus the @vite substitution (a bare page has none).
    private static func wrapBarePage(content: String, projectRoot: URL, diag: Diagnostics) -> Result {
        var html = resolveIncludes(in: content, projectRoot: projectRoot)
        html = resolveComponents(in: html, projectRoot: projectRoot)
        html = resolveAssetEchoes(in: html)

        let css = findCompiledCSS(projectRoot: projectRoot)
        let faCSS = inlineFontAwesome(in: html, projectRoot: projectRoot)
        let styleBlock: String
        if let css = css {
            let inlinedCSS = inlineCSSResources(css, projectRoot: projectRoot)
            let darkModeBridge = buildDarkModeBridge(from: css)
            styleBlock = "\(inlinedCSS)\n\(darkModeBridge)\n\(faCSS)\n\(barePageBaseCSS)"
        } else {
            styleBlock = "\(faCSS)\n\(barePageBaseCSS)"
        }

        let document = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(styleBlock)
        </style>
        </head>
        <body>
        <main class="qb-page">
        \(html)
        </main>
        </body>
        </html>
        """

        let withImages = inlineImages(document, projectRoot: projectRoot)
        return Result(html: withImages, didResolveLayout: true, didInlineCSS: css != nil,
                      diagnostics: diag)
    }

    // Layout/typography for the bare-page wrapper. Placed AFTER the inlined app CSS so these
    // rules win, guaranteeing a readable container regardless of the app's own body styles.
    private static let barePageBaseCSS = """
    [x-show] { display: none !important; }
    [x-cloak] { display: none !important; }
    [wire\\:loading],[wire\\:loading\\.flex],[wire\\:loading\\.block],[wire\\:loading\\.inline],[wire\\:loading\\.inline-flex],[wire\\:loading\\.grid],[wire\\:loading\\.table],[wire\\:loading\\.delay]{display:none!important}
    html { background: #fff; }
    body { margin: 0; background: #fff; color: #27272a; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Helvetica, Arial, sans-serif; }
    .qb-page { max-width: 72rem; margin: 0 auto; padding: 2rem; }
    \(DefaultStylesheet.fluxShimCSS)
    """

    private static func postProcess(composed: String, projectRoot: URL, diag: Diagnostics) -> Result {
        var html = resolveIncludes(in: composed, projectRoot: projectRoot)
        html = resolveComponents(in: html, projectRoot: projectRoot)
        html = resolveAssetEchoes(in: html)
        let css = findCompiledCSS(projectRoot: projectRoot)
        html = inlineAssets(html, css: css, projectRoot: projectRoot)
        html = inlineImages(html, projectRoot: projectRoot)
        return Result(html: html, didResolveLayout: true, didInlineCSS: css != nil,
                      diagnostics: diag)
    }

    // MARK: - Path Containment

    /// Joins `relativePath` onto `base` and returns the result ONLY if it stays inside
    /// `base`; nil otherwise.
    ///
    /// Every path fed to the asset inliners comes from template text, which is
    /// untrusted — the previewed `.blade.php` may be hostile, and so may the project
    /// around it. Without this, `<img src="/../../../secret.png">` resolves through
    /// `public/` and out into the home folder, which the extension can read in full
    /// (see BladeQuickLook.entitlements). The dot-notation resolvers (`@include`,
    /// `@extends`, component names) don't need this — they convert `.` to `/` before
    /// building a path, so `..` can never survive — but anything taking a raw URL or
    /// `src` value does.
    ///
    /// A `..` that stays in bounds (`/css/../img/logo.png`) is deliberately allowed —
    /// rejecting every `..` would break legitimate paths.
    private static func containedURL(
        _ relativePath: String, under base: URL, projectRoot: URL
    ) -> URL? {
        contain(base.appendingPathComponent(relativePath), within: base, projectRoot: projectRoot)
    }

    /// `containedURL` for a URL that has already been joined against some other
    /// directory — the boundary being checked isn't always what the path was
    /// resolved relative to (see `inlineFontURLs`).
    ///
    /// Two stages, because symlinks and dot segments are different problems:
    ///
    /// 1. **Lexical** — with `..` collapsed but symlinks left alone, the path must be
    ///    inside `base`. This is what stops `<img src="/../../secret.png">`.
    /// 2. **After symlinks** — the real file must be inside `projectRoot`. This stops a
    ///    link planted under `public/` by a hostile project from reaching the rest of
    ///    the home folder.
    ///
    /// Stage 2 checks the project, not `base`, on purpose: `artisan storage:link` makes
    /// `public/storage -> ../storage/app/public`, so every Laravel app serving uploads
    /// references files that legitimately leave `public/` while staying in the project.
    /// Resolving symlinks against `base` instead would silently stop `/storage/…`
    /// images from rendering.
    private static func contain(_ candidate: URL, within base: URL, projectRoot: URL) -> URL? {
        let basePath = base.standardizedFileURL.path
        let lexical = candidate.standardizedFileURL
        guard lexical.path == basePath || lexical.path.hasPrefix(basePath + "/") else {
            return nil
        }

        let rootPath = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = lexical.resolvingSymlinksInPath()
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return resolved
    }

    // MARK: - Find Laravel Root

    private static func findLaravelRoot(from fileURL: URL) -> URL? {
        var dir = fileURL.deletingLastPathComponent()
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("artisan").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: - Component Layout Resolution (<x-layouts.name>)

    private static func resolveComponentLayout(source: String, projectRoot: URL, diag: Diagnostics) -> String? {
        // Match opening tag: <x-NAME attrs...>  (potentially multiline).
        // Quote-aware attrs (see quotedAttrRun) so a `>` inside a quoted value doesn't
        // end the tag early, without letting a stray quote turn the scan quadratic.
        guard let openRegex = try? NSRegularExpression(
            pattern: #"<x-([\w\-\.]+)("# + quotedAttrRun + #")>"#,
            options: []
        ) else { return nil }

        let nsSource = source as NSString
        let matches = openRegex.matches(
            in: source, options: [],
            range: NSRange(location: 0, length: nsSource.length)
        )

        // A page's layout tag is usually first, but not always — e.g. a
        // self-closing component above it. Try each candidate until one has a
        // closing tag AND resolves to a full-document template. Cap the scan;
        // a page whose first 10 x-tags aren't layouts doesn't have one.
        for openMatch in matches.prefix(10) {
            guard let nameRange = Range(openMatch.range(at: 1), in: source) else { continue }
            let componentName = String(source[nameRange])

            // Parse props from attributes
            let attrsNSRange = openMatch.range(at: 2)
            let attrsString = attrsNSRange.location == NSNotFound ? "" : nsSource.substring(with: attrsNSRange)
            let props = parseProps(from: attrsString)

            // Find closing tag
            let closingTag = "</x-\(componentName)>"
            guard let openEnd = Range(openMatch.range, in: source)?.upperBound,
                  let closingRange = source.range(of: closingTag, range: openEnd..<source.endIndex) else {
                logger.info("No closing tag for <x-\(componentName)>; trying next tag")
                continue
            }

            // Resolve the layout file BEFORE doing any work on the tag's contents.
            // Slot extraction is the expensive step here, and running it for a
            // component that doesn't exist on disk meant any `<x-anything>…</x-anything>`
            // in an untrusted file could drive it. (resolveComponents already checks
            // in this order.)
            guard let layoutFile = resolveComponentToFile(name: componentName, projectRoot: projectRoot) else {
                logger.info("Cannot resolve component: \(componentName); trying next tag")
                continue
            }

            // Extract content between opening and closing tags
            let innerContent = String(source[openEnd..<closingRange.lowerBound])

            // Extract named slots and default slot
            let (namedSlots, defaultSlot) = extractSlots(from: innerContent)

            let layoutSource: String
            do {
                layoutSource = try String(contentsOf: layoutFile, encoding: .utf8)
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoPermissionError {
                    diag.readDenied = true
                }
                logger.error("Cannot read layout file: \(layoutFile.path)")
                continue
            }

            // Only a full HTML document is a page layout; regular components
            // (<x-card> etc.) defer to the bare-page path, which inlines them.
            let lowerLayout = layoutSource.lowercased()
            guard lowerLayout.contains("<html") || lowerLayout.contains("<!doctype") else {
                logger.info("<x-\(componentName)> is a component, not a page layout — trying next tag")
                continue
            }
            logger.info("Read layout: \(layoutFile.lastPathComponent)")

            return composeLayout(
                layout: layoutSource,
                defaultSlot: defaultSlot,
                namedSlots: namedSlots,
                props: props
            )
        }
        return nil
    }

    // MARK: - Livewire Full-Page Layout Resolution

    /// A full-page Livewire view (under `resources/views/livewire/…`) carries no in-file layout
    /// reference: the layout is attached on the component CLASS via `#[Layout('…')]` or a fluent
    /// `->layout('…')` in `render()`. So unlike `<x-layout>`/`@extends`, there's nothing in the
    /// `.blade` to key off. This composes the page into that discovered layout's `{{ $slot }}` so
    /// it renders inside the real app shell, matching how `<x-layouts.app>` pages already render.
    /// Returns nil (→ bare-page/content-only fallback) when the view isn't a Livewire view, its
    /// class declares no layout (a nested component, not a page), or the layout isn't a full doc.
    private static func resolveLivewireLayout(source: String, fileURL: URL, projectRoot: URL, diag: Diagnostics) -> String? {
        // Scope strictly to Livewire component views so arbitrary bare partials in apps that
        // render via <x-layouts.app> instead aren't wrapped unexpectedly.
        guard fileURL.path.contains("/resources/views/livewire/") else { return nil }

        // The view maps to a Livewire component class. If we can't resolve a real class, treat the
        // view as content-only (an anonymous/Volt/edge view we can't reason about as a page).
        guard let component = componentClass(fileURL: fileURL, projectRoot: projectRoot) else {
            return nil
        }

        // Decide the layout, distinguishing a full PAGE from an embedded nested component:
        //   1. An explicit `->layout('…')` / `#[Layout('…')]` on the class names the layout outright.
        //   2. Otherwise it's a page only if its class is BOUND TO A ROUTE — vanilla Livewire pages
        //      rely on the config-default layout and declare none, while nested components
        //      (share-button, modals, badges) are never routed and must stay content-only.
        let layoutName: String
        if let explicit = layoutFromComponentClass(file: component.file) {
            layoutName = explicit
        } else if componentClassIsRouted(fqn: component.fqn, projectRoot: projectRoot) {
            layoutName = livewireConfigLayout(projectRoot: projectRoot) ?? "components.layouts.app"
        } else {
            return nil
        }

        guard let layoutFile = resolveViewName(layoutName, projectRoot: projectRoot) else {
            logger.info("Livewire layout '\(layoutName)' not found on disk; deferring to bare-page render")
            return nil
        }
        let layoutSource: String
        do {
            layoutSource = try String(contentsOf: layoutFile, encoding: .utf8)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoPermissionError {
                diag.readDenied = true
            }
            logger.info("Livewire layout '\(layoutName)' unreadable; deferring to bare-page render")
            return nil
        }

        // Only a full HTML document is a page layout. A partial/component resolved by name would
        // produce a fragment with no <head> for CSS — defer to the bare-page path in that case.
        let lower = layoutSource.lowercased()
        guard lower.contains("<html") || lower.contains("<!doctype") else {
            logger.info("Livewire layout '\(layoutName)' is not a full document; deferring to bare-page render")
            return nil
        }
        logger.info("Composing Livewire page into layout: \(layoutFile.lastPathComponent)")

        // The page IS the default slot. Named slots/props don't apply (a Livewire page passes
        // none through the view file); runtime layout data ($auth, $user, …) is stripped later.
        return composeLayout(layout: layoutSource, defaultSlot: source, namedSlots: [:], props: [:])
    }

    /// Maps a Livewire view file to its component class by Livewire's view⇄class convention
    /// (`resources/views/livewire/pages/foo-bar.blade.php` ⇄ `App\Livewire\Pages\FooBar` ⇄
    /// `app/Livewire/Pages/FooBar.php`). Returns the class file (which must exist on disk) and its
    /// fully-qualified name. Assumes the default `App\Livewire` namespace (Livewire's standard).
    private static func componentClass(fileURL: URL, projectRoot: URL) -> (file: URL, fqn: String)? {
        let path = fileURL.path
        guard let marker = path.range(of: "/resources/views/livewire/") else { return nil }
        var relative = String(path[marker.upperBound...])   // e.g. "pages/dashboard.blade.php"
        guard relative.hasSuffix(".blade.php") else { return nil }
        relative.removeLast(".blade.php".count)              // "pages/dashboard"

        // kebab-or-snake segment → StudlyCase; "support/support-index" → "Support/SupportIndex"
        let parts = relative.split(separator: "/").map { segment in
            segment.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined()
        }
        guard !parts.isEmpty else { return nil }

        let classFile = projectRoot
            .appendingPathComponent("app/Livewire")
            .appendingPathComponent(parts.joined(separator: "/") + ".php")
        guard FileManager.default.fileExists(atPath: classFile.path) else { return nil }

        let fqn = (["App", "Livewire"] + parts).joined(separator: "\\")
        return (classFile, fqn)
    }

    /// Extracts the layout name declared on a component class, or nil if it declares none.
    private static func layoutFromComponentClass(file: URL) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        // Precedence: a fluent ->layout('…') in render() overrides the #[Layout('…')] attribute.
        // The non-greedy [^)]*? before the literal makes a ternary like
        // `->layout($authed ? 'layouts.app' : 'layouts.public', …)` capture the FIRST branch,
        // which is the authenticated layout — and the preview simulates an authenticated view.
        if let name = firstCapture(in: contents, pattern: #"->layout\s*\(\s*[^)]*?['"]([^'"]+)['"]"#) {
            return name
        }
        if let name = firstCapture(in: contents, pattern: #"#\[\s*Layout\s*\(\s*[^)\]]*?['"]([^'"]+)['"]"#) {
            return name
        }
        return nil
    }

    /// True if the component class is bound to a route — the signal it's a full page rather than an
    /// embedded nested component. Scans `routes/*.php` for the class by its FULLY-QUALIFIED name,
    /// either imported (`use App\Livewire\…\Foo;`) or referenced fully-qualified (`\App\…\Foo::class`).
    /// Matching the full FQN (never the bare short name) avoids a false positive when another
    /// namespace has a same-named class (e.g. routed `Pages\Notifications` vs nested `Notifications`).
    private static func componentClassIsRouted(fqn: String, projectRoot: URL) -> Bool {
        let routesDir = projectRoot.appendingPathComponent("routes")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: routesDir, includingPropertiesForKeys: nil
        ) else { return false }

        let fqnEsc = NSRegularExpression.escapedPattern(for: fqn)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:use\s+\\?"# + fqnEsc + #"\s*(?:;|\s+as\b)|(?<![\w\\])\\?"# + fqnEsc + #"::class)"#
        ) else { return false }

        for file in files where file.pathExtension == "php" {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(location: 0, length: (contents as NSString).length)
            if regex.firstMatch(in: contents, options: [], range: range) != nil { return true }
        }
        return false
    }

    /// Reads the Livewire single-component full-page layout default from `config/livewire.php`.
    /// Prefers the `component_layout` key some apps use, then stock Livewire's `layout` key. Returns
    /// nil if the config isn't published (caller falls back to Livewire's built-in default).
    private static func livewireConfigLayout(projectRoot: URL) -> String? {
        let configFile = projectRoot.appendingPathComponent("config/livewire.php")
        guard let contents = try? String(contentsOf: configFile, encoding: .utf8) else { return nil }
        if let name = firstCapture(in: contents, pattern: #"['"]component_layout['"]\s*=>\s*['"]([^'"]+)['"]"#) {
            return name
        }
        // Match the exact `'layout'` key (closing quote right after `layout`) so it can't match
        // inside `'component_layout'` or `'layouts'`.
        if let name = firstCapture(in: contents, pattern: #"['"]layout['"]\s*=>\s*['"]([^'"]+)['"]"#) {
            return name
        }
        return nil
    }

    /// Returns capture group 1 of the first match of `pattern` in `text`, or nil.
    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Resolve @include Directives

    /// Total bytes of template content one resolution pass may inline. The depth caps
    /// alone do NOT bound output: a partial (or component) that references itself k
    /// times expands to the sum of k^i over the allowed depths, so a 16-byte file whose
    /// partial included itself 16 times produced 16.8 MB, and an 11-byte file whose
    /// component referenced itself 50 times produced 1.4 MB — which then fed the
    /// transpiler. Bounding the product, not just the depth, is what actually stops it.
    private static let maxTemplateExpansion = 2 * 1024 * 1024

    /// How many `<x-…>` tags may fail to find a closing partner before `resolveComponents`
    /// stops looking for more. Each failed search scans to end-of-document, so this is
    /// what keeps a file full of unpartnered tags linear instead of quadratic. Well
    /// above anything hand-written markup produces, and it counts failures only — a page
    /// of hundreds of well-formed components never approaches it.
    private static let maxFailedPairSearches = 64

    /// Shared across one `resolveIncludes` recursion so sibling branches draw on the
    /// same allowance — a per-call limit would still multiply out across fan-out.
    private final class ExpansionBudget {
        private var remaining: Int
        init(_ bytes: Int) { remaining = bytes }
        /// Debits `cost`, or returns false when it no longer fits.
        func consume(_ cost: Int) -> Bool {
            guard cost <= remaining else { return false }
            remaining -= cost
            return true
        }
    }

    /// Recursively resolves `@include('name')` directives by reading and inlining Blade partials.
    private static func resolveIncludes(
        in html: String, projectRoot: URL, depth: Int = 0, budget: ExpansionBudget? = nil
    ) -> String {
        guard depth < 5 else { return html }
        let budget = budget ?? ExpansionBudget(maxTemplateExpansion)

        guard let regex = try? NSRegularExpression(
            pattern: #"@include\s*\(\s*['"]([^'"]*)['"]\s*(?:,\s*[^)]*)?\)"#,
            options: []
        ) else { return html }

        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html, options: [],
            range: NSRange(location: 0, length: nsHTML.length)
        )

        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }

            let includeName = String(result[nameRange])
            let includePath = includeName.replacingOccurrences(of: ".", with: "/")
            let includeFile = projectRoot
                .appendingPathComponent("resources/views")
                .appendingPathComponent(includePath + ".blade.php")

            if let contents = try? String(contentsOf: includeFile, encoding: .utf8) {
                guard budget.consume(contents.utf8.count) else {
                    // Budget spent — stop inlining rather than keep multiplying.
                    // The name is deliberately omitted: it comes from the template.
                    result.replaceSubrange(
                        fullRange, with: "<!-- quickblade: include expansion limit reached -->")
                    continue
                }
                let resolved = resolveIncludes(
                    in: contents, projectRoot: projectRoot, depth: depth + 1, budget: budget)
                result.replaceSubrange(fullRange, with: resolved)
                logger.info("Inlined @include('\(includeName)')")
            } else {
                // Leave a non-rendering marker so a missing partial is debuggable in source.
                // Strip ">" from the name so it can't terminate the comment early.
                let safeName = includeName.replacingOccurrences(of: ">", with: "")
                result.replaceSubrange(fullRange, with: "<!-- quickblade: include not found: \(safeName) -->")
            }
        }

        return result
    }

    // MARK: - Resolve Inline Components

    /// Composes a component's Blade source with its slot(s), props, and `$attributes` bag,
    /// mirroring composeLayout's order (default slot, then named slots, then props — all
    /// whitespace-tolerant echoes). Shared by both the self-closing and paired resolution
    /// paths in resolveComponents below.
    private static func composeInlineComponent(
        source: String,
        defaultSlot: String,
        namedSlots: [String: String],
        props: [String: String],
        callerAttrs: [(key: String, value: String?)]
    ) -> String {
        let propDefaults = parsePropsDefaults(source)
        var composed = stripPropsDeclaration(source)

        // @php evaluation scope: @props defaults overridden by caller props.
        var scope = propDefaults
        for (key, value) in props { scope[key] = value }
        let phpVars = evaluatePhpAssignments(in: composed, scope: scope)

        composed = replaceAttributesBag(in: composed, callerAttrs: callerAttrs)
        composed = replaceEcho(of: "slot", in: composed, with: defaultSlot)
        for (name, content) in namedSlots {
            composed = replaceEcho(of: name, in: composed, with: content)
        }
        return substituteComputedAndProps(
            in: composed, phpVars: phpVars, props: props, propDefaults: propDefaults)
    }

    // MARK: - $attributes Bag (static approximation)
    //
    // Real Blade attribute bags are runtime objects (ComponentAttributeBag) with full
    // merge/filter/conditional semantics. This is a STATIC approximation good enough for a
    // preview: it resolves the three forms that account for almost every real component
    // (bare passthrough, ->merge() with literal defaults, ->except() by key) from the
    // caller tag's literal attribute text. Any other `$attributes->...` chain (dynamic
    // values, ->class(), ->only(), conditionals, etc.) is left untouched for
    // BladeTranspiler's Phase 3 placeholder handling — same as before this feature existed.

    /// Replaces `{{ $attributes }}` / `{{ $attributes->merge([...]) }}` /
    /// `{{ $attributes->except([...]) }}` (and their `{!! !!}` variants) inside a component
    /// template with the serialized `key="value"` attributes computed from `callerAttrs`.
    private static func replaceAttributesBag(in source: String, callerAttrs: [(key: String, value: String?)]) -> String {
        var result = source
        let openTag = #"(?:\{\{|\{!!)"#
        let closeTag = #"(?:\}\}|!!\})"#
        // Single-level array literal — merge()/except() array args in real components don't
        // nest. A nested literal falls through unmatched and is left for Phase 3, as documented.
        let arrayLiteral = #"\[[^\[\]]*\]"#

        // ->merge([...]) — must run before the bare-$attributes pass below.
        if let regex = try? NSRegularExpression(
            pattern: openTag + #"\s*\$attributes->merge\(\s*("# + arrayLiteral + #")\s*\)\s*"# + closeTag,
            options: []
        ) {
            let ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let literalRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let serialized = composeAttributesMerge(
                    defaultsLiteral: String(result[literalRange]), callerAttrs: callerAttrs)
                result.replaceSubrange(fullRange, with: serialized)
            }
        }

        // ->except([...]) or ->except('key') — must also run before the bare pass.
        if let regex = try? NSRegularExpression(
            pattern: openTag + #"\s*\$attributes->except\(\s*("# + arrayLiteral + #"|'[^']*'|"[^"]*")\s*\)\s*"# + closeTag,
            options: []
        ) {
            let ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let argRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                let excludeKeys = parseKeyList(String(result[argRange]))
                let filtered = callerAttrs.filter { !excludeKeys.contains($0.key) }
                result.replaceSubrange(fullRange, with: serializeAttrs(filtered))
            }
        }

        // Bare {{ $attributes }} — the merge/except passes above already consumed those forms,
        // so anything still matching here really is a plain passthrough echo.
        if let regex = try? NSRegularExpression(
            pattern: openTag + #"\s*\$attributes\s*"# + closeTag,
            options: []
        ) {
            let ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(fullRange, with: serializeAttrs(callerAttrs))
            }
        }

        return result
    }

    /// Computes `->merge([...])` output: defaults come from the array literal's `'key' =>
    /// 'literal'` pairs (non-literal values are skipped — this isn't a PHP evaluator). `class`
    /// concatenates default-then-caller; every other key lets the caller's value win when
    /// present. Caller attrs with no matching default key are appended afterward, in the
    /// caller's original order.
    private static func composeAttributesMerge(
        defaultsLiteral: String, callerAttrs: [(key: String, value: String?)]
    ) -> String {
        let defaults = parseArrayLiteralPairs(defaultsLiteral)
        // updateValue (not subscript-assign) so a bare caller attr (value == nil) is stored as
        // a PRESENT key mapped to nil, distinguishable from "caller didn't pass this key at
        // all" — `dict[key] = someOptional` has a well-known gotcha where assigning nil removes
        // the entry instead of storing it.
        var callerDict: [String: String?] = [:]
        for (key, value) in callerAttrs { callerDict.updateValue(value, forKey: key) }

        var pairs: [(key: String, value: String?)] = []
        for (key, defaultValue) in defaults {
            if let callerValue = callerDict[key] {
                if key == "class" {
                    pairs.append((key, callerValue.map { defaultValue + " " + $0 } ?? defaultValue))
                } else {
                    // Caller wins whenever the key is present — even bare (nil), which means
                    // the caller's boolean attr overrides a default value with no value at all.
                    pairs.append((key, callerValue))
                }
            } else {
                pairs.append((key, defaultValue))
            }
        }
        let defaultKeys = Set(defaults.map(\.key))
        for (key, value) in callerAttrs where !defaultKeys.contains(key) {
            pairs.append((key, value))
        }
        return serializeAttrs(pairs)
    }

    /// Parses `'key' => 'value'` (or double-quoted) pairs from a Blade array literal such as
    /// `['type' => 'submit', 'class' => 'btn']`. A pair whose value isn't a plain string
    /// literal (e.g. `'x' => $foo`) doesn't match and is silently skipped — this is a static
    /// approximation, not a PHP evaluator. Order is preserved.
    private static func parseArrayLiteralPairs(_ arrayLiteral: String) -> [(key: String, value: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:'([^']*)'|"([^"]*)")\s*=>\s*(?:'([^']*)'|"([^"]*)")"#,
            options: []
        ) else { return [] }
        let ns = arrayLiteral as NSString
        let matches = regex.matches(in: arrayLiteral, options: [], range: NSRange(location: 0, length: ns.length))
        var result: [(key: String, value: String)] = []
        for match in matches {
            let key: String
            if match.range(at: 1).location != NSNotFound {
                key = ns.substring(with: match.range(at: 1))
            } else if match.range(at: 2).location != NSNotFound {
                key = ns.substring(with: match.range(at: 2))
            } else { continue }
            let value: String
            if match.range(at: 3).location != NSNotFound {
                value = ns.substring(with: match.range(at: 3))
            } else if match.range(at: 4).location != NSNotFound {
                value = ns.substring(with: match.range(at: 4))
            } else { continue }
            result.append((key: key, value: value))
        }
        return result
    }

    /// Extracts every quoted string token from an `->except(...)` argument, whether it's a
    /// single key (`'title'`) or an array literal (`['title', 'other']`).
    private static func parseKeyList(_ raw: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"'([^']*)'|"([^"]*)""#, options: []) else { return [] }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
        var keys = Set<String>()
        for match in matches {
            if match.range(at: 1).location != NSNotFound {
                keys.insert(ns.substring(with: match.range(at: 1)))
            } else if match.range(at: 2).location != NSNotFound {
                keys.insert(ns.substring(with: match.range(at: 2)))
            }
        }
        return keys
    }

    /// Serializes attribute pairs as space-joined `key="value"` (HTML-escaped values). A `nil`
    /// value means a bare/boolean attribute (`required`, `disabled`, …) — emitted as the bare
    /// key with no `="..."`, not `key=""`.
    private static func serializeAttrs(_ pairs: [(key: String, value: String?)]) -> String {
        pairs.map { pair in
            guard let value = pair.value else { return pair.key }
            return "\(pair.key)=\"\(DefaultStylesheet.escapeHTML(value))\""
        }.joined(separator: " ")
    }

    /// Builds the caller-attribute list from a component tag's raw attribute string, for
    /// `$attributes` bag serialization. Unlike `parseProps` (which camelCases keys for Blade
    /// prop echoes), this preserves the original HTML attribute spelling (`data-x`, `for`, …).
    /// `:`-prefixed dynamic binds are included only when `resolveLiteralExpression` can resolve
    /// them to static text (a quoted string or a `__('...')` call); other dynamic binds
    /// (`:value="old('username')"`) are runtime values and are dropped from this list — they
    /// remain available to `parseProps` for prop-echo substitution as before.
    /// A bare/boolean attribute (`required`, `disabled`, `wire:navigate`, …) — any `[\w:.\-]+`
    /// token not followed by `=` — is also captured, with a `nil` value marking it as valueless
    /// (serialized bare by `serializeAttrs`, never as `key=""`). The self-closing tag's own
    /// trailing `/` is never captured: `/` isn't in the bare-token character class, and the
    /// caller (resolveComponents' selfClosingAttrs run) already excludes it from `attrsString`.
    private static func parseCallerAttributes(from attrsString: String) -> [(key: String, value: String?)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(:)?([\w\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')|([\w:.\-]+)(?!\s*=)"#,
            options: []
        ) else { return [] }

        let ns = attrsString as NSString
        let matches = regex.matches(in: attrsString, options: [], range: NSRange(location: 0, length: ns.length))

        var result: [(key: String, value: String?)] = []
        for match in matches {
            if match.range(at: 2).location != NSNotFound {
                guard let keyRange = Range(match.range(at: 2), in: attrsString) else { continue }
                let key = String(attrsString[keyRange])
                let isDynamic = match.range(at: 1).location != NSNotFound

                let rawValue: String
                if match.range(at: 3).location != NSNotFound, let r = Range(match.range(at: 3), in: attrsString) {
                    rawValue = String(attrsString[r])
                } else if match.range(at: 4).location != NSNotFound, let r = Range(match.range(at: 4), in: attrsString) {
                    rawValue = String(attrsString[r])
                } else { continue }

                if isDynamic {
                    guard let literal = resolveLiteralExpression(rawValue) else { continue }
                    result.append((key: key, value: literal))
                } else {
                    result.append((key: key, value: rawValue))
                }
            } else if match.range(at: 5).location != NSNotFound {
                guard let keyRange = Range(match.range(at: 5), in: attrsString) else { continue }
                result.append((key: String(attrsString[keyRange]), value: nil))
            }
        }
        return result
    }

    /// Resolves a `:`-bound attribute expression to static text if it's trivially literal: a
    /// quoted string (`'...'`/`"..."`), or `__('...')`/`__("...")` (a translation call with a
    /// literal key — resolved to that key's text as a static approximation, not a real
    /// translation lookup). Anything else (function calls, variables, concatenation) is a
    /// runtime value and returns nil.
    private static func resolveLiteralExpression(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast())
        }
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return translationLiteralText(trimmed)
    }

    /// Extracts the literal text from a `__('...')`/`__("...")` call, or nil if the argument
    /// isn't a plain string literal.
    private static func translationLiteralText(_ expr: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^__\(\s*(?:'([^']*)'|"([^"]*)")\s*\)$"#,
            options: []
        ) else { return nil }
        let ns = expr as NSString
        guard let match = regex.firstMatch(in: expr, options: [], range: NSRange(location: 0, length: ns.length))
        else { return nil }
        if match.range(at: 1).location != NSNotFound { return ns.substring(with: match.range(at: 1)) }
        if match.range(at: 2).location != NSNotFound { return ns.substring(with: match.range(at: 2)) }
        return nil
    }

    /// Resolves inline `<x-name>...</x-name>` AND self-closing `<x-name />` component tags by
    /// reading their Blade templates and composing with slot content. A self-closing tag that
    /// can't be resolved to a file (e.g. a vendor-package component with no local Blade source)
    /// is left untouched — BladeTranspiler Phase 4 strips it as before.
    private static func resolveComponents(
        in html: String, projectRoot: URL, depth: Int = 0, budget: ExpansionBudget? = nil
    ) -> String {
        guard depth < 3 else { return html }
        // Same reasoning as resolveIncludes: the depth cap bounds nesting, not
        // fan-out. A component whose template references itself 50 times turned
        // 220 bytes into 27 MB in 22 seconds before this.
        let budget = budget ?? ExpansionBudget(maxTemplateExpansion)

        // Possessive (++) on the unquoted run prevents catastrophic backtracking on an unclosed tag.
        let quotedAttrs = quotedAttrRun

        // Self-closing form's attrs run: unlike quotedAttrs above, `/` is EXCLUDED
        // from the unquoted alternative (mirrors BladeTranspiler's fluxAttrs) — a
        // trailing bare/boolean attribute (`required`, `disabled`, …) has no closing
        // quote before the tag's own `/>`, so a possessive run that allows `/` would
        // swallow that slash and the `\s*/>` suffix could never match. Verified against
        // `<x-text-input id="username" required />`, which silently failed to resolve
        // (and to strip) with the /-inclusive pattern.
        let selfClosingAttrs = selfClosingAttrRun

        // Match opening <x-name> tags. (?<!/)> rejects self-closing forms —
        // `<x-card />` must not pair with a later `</x-card>`.
        guard let openRegex = try? NSRegularExpression(
            pattern: "<x-([\\w\\-\\.:]+)(\\s" + quotedAttrs + ")?(?<!/)>",
            options: []
        ),
        let selfClosingRegex = try? NSRegularExpression(
            pattern: "<x-([\\w\\-\\.:]+)(\\s" + selfClosingAttrs + ")?\\s*/>",
            options: []
        ) else { return html }

        var result = html
        var changed = false
        // Misses are cached too (hence the double optional): a page full of tags naming
        // components that don't exist would otherwise re-stat the filesystem three
        // times per tag.
        var componentCache: [String: String?] = [:]

        func loadComponentSource(_ name: String) -> String? {
            if let cached = componentCache[name] { return cached }
            let source = resolveComponentToFile(name: name, projectRoot: projectRoot)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            componentCache[name] = source
            return source
        }

        func attrsString(from match: NSTextCheckingResult, in text: String) -> String {
            guard match.numberOfRanges > 2,
                  match.range(at: 2).location != NSNotFound,
                  let attrsRange = Range(match.range(at: 2), in: text) else { return "" }
            return String(text[attrsRange])
        }

        // Self-closing components first: <x-name attrs />. Processed before paired
        // tags so a self-closing component nested inside a not-yet-resolved paired
        // component's body is already inlined by the time that body is extracted.
        let selfClosingMatches = selfClosingRegex.matches(
            in: result, options: [],
            range: NSRange(location: 0, length: (result as NSString).length)
        )
        for match in selfClosingMatches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }

            let name = String(result[nameRange])
            guard let componentSource = loadComponentSource(name) else { continue }
            // Budget spent: leave the tag alone. Phase 4 strips it, as it always
            // did for components with no local Blade source.
            guard budget.consume(componentSource.utf8.count) else { continue }

            let rawAttrs = attrsString(from: match, in: result)
            let props = parseProps(from: rawAttrs)
            let callerAttrs = parseCallerAttributes(from: rawAttrs)
            let composed = composeInlineComponent(
                source: componentSource, defaultSlot: "", namedSlots: [:], props: props, callerAttrs: callerAttrs)

            result.replaceSubrange(fullRange, with: composed)
            changed = true
            logger.info("Resolved self-closing inline component <x-\(name) />")
        }

        // Paired components: <x-name>...</x-name>. Re-scan the (possibly
        // self-closing-updated) result so ranges are valid.
        let pairedMatches = openRegex.matches(
            in: result, options: [],
            range: NSRange(location: 0, length: (result as NSString).length)
        )

        // Searching for a closing tag that isn't there costs a scan to end-of-document,
        // so thousands of unpartnered `<x-…>` tags cost thousands of full scans. Real
        // markup has a handful of unclosed tags at worst — by the time this many have
        // failed, the document is malformed and the remaining tags are almost certainly
        // malformed too. Give up looking rather than keep paying. Tags left unresolved
        // here are stripped by phase 4, exactly as an unresolvable component is.
        // Counts FAILED searches only, so a page of hundreds of well-formed components
        // is untouched.
        var failedPairSearches = 0

        // Process in reverse to preserve earlier ranges
        for match in pairedMatches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: result),
                  let fullOpenRange = Range(match.range, in: result) else { continue }

            let name = String(result[nameRange])

            // Resolve the component BEFORE hunting for its closing tag. That search
            // runs to end-of-document when there is no match, so N unmatched `<x-…>`
            // tags cost N full-tail scans — quadratic on input a hostile file
            // controls. A component that doesn't exist can't be composed whatever the
            // scan finds, and the lookup is cached, so checking first turns the
            // common bad case into one filesystem probe.
            guard let componentSource = loadComponentSource(name) else { continue }

            guard failedPairSearches < maxFailedPairSearches else { continue }

            // Find the matching closing tag
            guard let closingRange = result.range(
                of: "</x-\(name)>",
                range: fullOpenRange.upperBound..<result.endIndex
            ) else {
                failedPairSearches += 1
                continue
            }

            guard budget.consume(componentSource.utf8.count) else { continue }

            // Extract inner content, then split it into the default slot and any
            // named <x-slot> blocks (mirrors resolveComponentLayout's handling).
            let innerContent = String(result[fullOpenRange.upperBound..<closingRange.lowerBound])
            let (namedSlots, defaultSlot) = extractSlots(from: innerContent)

            let rawAttrs = attrsString(from: match, in: result)
            let props = parseProps(from: rawAttrs)
            let callerAttrs = parseCallerAttributes(from: rawAttrs)
            let composed = composeInlineComponent(
                source: componentSource, defaultSlot: defaultSlot, namedSlots: namedSlots,
                props: props, callerAttrs: callerAttrs)

            // Replace the full component tag (opening + content + closing)
            let fullRange = fullOpenRange.lowerBound..<closingRange.upperBound
            result.replaceSubrange(fullRange, with: composed)
            changed = true
            logger.info("Resolved inline component <x-\(name)>")
        }

        // Recurse for any newly introduced components
        if changed {
            result = resolveComponents(
                in: result, projectRoot: projectRoot, depth: depth + 1, budget: budget)
        }

        return result
    }


    // MARK: - Multi-Strategy Component Resolution

    /// Tries three strategies to resolve an `<x-name>` component to a Blade file:
    /// 1. Anonymous component: `resources/views/components/{dots→slashes}.blade.php`
    /// 2. Class-based component: `app/View/Components/{PascalCase}.php` → parse render() → view file
    /// 3. Views directory fallback: `resources/views/{dots→slashes}.blade.php`
    private static func resolveComponentToFile(name: String, projectRoot: URL) -> URL? {
        // Strategy 1: Anonymous component
        let anonymousPath = name.replacingOccurrences(of: ".", with: "/")
        let anonymousFile = projectRoot
            .appendingPathComponent("resources/views/components")
            .appendingPathComponent(anonymousPath + ".blade.php")
        if FileManager.default.fileExists(atPath: anonymousFile.path) {
            logger.info("Resolved via anonymous component: \(anonymousFile.lastPathComponent)")
            return anonymousFile
        }

        // Strategy 2: Class-based component
        let pascalPath = kebabToPascalCase(name)
        let classFile = projectRoot
            .appendingPathComponent("app/View/Components")
            .appendingPathComponent(pascalPath + ".php")
        if FileManager.default.fileExists(atPath: classFile.path),
           let viewName = parseViewFromComponentClass(classFile),
           let viewFile = resolveViewName(viewName, projectRoot: projectRoot) {
            logger.info("Resolved via class-based component: \(classFile.lastPathComponent) → \(viewName)")
            return viewFile
        }

        // Strategy 3: Views directory fallback
        if let viewFile = resolveViewName(name, projectRoot: projectRoot) {
            logger.info("Resolved via views fallback: \(viewFile.lastPathComponent)")
            return viewFile
        }

        return nil
    }

    /// Converts a kebab-case component name to a PascalCase path.
    /// `app-layout` → `AppLayout`
    /// `layouts.app-sidebar` → `Layouts/AppSidebar`
    private static func kebabToPascalCase(_ name: String) -> String {
        return name.split(separator: ".").map { segment in
            segment.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined()
        }.joined(separator: "/")
    }

    /// Reads a PHP component class file and extracts the view name from its render() method.
    /// Looks for patterns like `return view('layouts.app')` or `return view("layouts.app")`.
    private static func parseViewFromComponentClass(_ fileURL: URL) -> String? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: #"view\(\s*['"]([^'"]+)['"]\s*\)"#,
            options: []
        ) else { return nil }

        let nsContents = contents as NSString
        guard let match = regex.firstMatch(
            in: contents, options: [],
            range: NSRange(location: 0, length: nsContents.length)
        ) else { return nil }

        guard let viewRange = Range(match.range(at: 1), in: contents) else { return nil }
        return String(contents[viewRange])
    }

    /// Resolves a dot-notation view name to a Blade file path.
    /// `layouts.app` → `resources/views/layouts/app.blade.php`
    private static func resolveViewName(_ name: String, projectRoot: URL) -> URL? {
        let viewPath = name.replacingOccurrences(of: ".", with: "/")
        let viewFile = projectRoot
            .appendingPathComponent("resources/views")
            .appendingPathComponent(viewPath + ".blade.php")
        return FileManager.default.fileExists(atPath: viewFile.path) ? viewFile : nil
    }

    // MARK: - Extends Layout Resolution (@extends('name'))

    private static func resolveExtendsLayout(source: String, projectRoot: URL, diag: Diagnostics) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"@extends\s*\(\s*['"]([^'"]*)['"]\s*\)"#,
            options: []
        ) else { return nil }

        let nsSource = source as NSString
        guard let match = regex.firstMatch(
            in: source, options: [],
            range: NSRange(location: 0, length: nsSource.length)
        ) else { return nil }

        guard let nameRange = Range(match.range(at: 1), in: source) else { return nil }
        let layoutName = String(source[nameRange])

        guard let layoutFile = resolveViewName(layoutName, projectRoot: projectRoot) else {
            logger.error("Cannot resolve extends layout: \(layoutName)")
            diag.layoutMissing = true
            return nil
        }

        let layoutSource: String
        do {
            layoutSource = try String(contentsOf: layoutFile, encoding: .utf8)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoPermissionError {
                diag.readDenied = true
            }
            logger.error("Cannot read extends layout: \(layoutFile.path)")
            return nil
        }
        logger.info("Read extends layout: \(layoutFile.lastPathComponent)")

        // Extract sections from the page
        let sections = extractSections(from: source)

        var composed = layoutSource

        // Layout-side `@section('name') default @show`: the page's section
        // overrides the default; otherwise the default renders in place.
        if let showRegex = try? NSRegularExpression(
            pattern: #"@section\s*\(\s*['"]([^'"]*)['"]\s*\)\s*([\s\S]*?)@show(?!\w)"#,
            options: []
        ) {
            let nsComposed = composed as NSString
            let matches = showRegex.matches(
                in: composed, options: [],
                range: NSRange(location: 0, length: nsComposed.length)
            )
            for match in matches.reversed() {
                guard let nameRange = Range(match.range(at: 1), in: composed),
                      let defaultRange = Range(match.range(at: 2), in: composed),
                      let fullRange = Range(match.range, in: composed) else { continue }
                let name = String(composed[nameRange])
                let body = sections[name] ?? String(composed[defaultRange])
                composed.replaceSubrange(fullRange, with: body)
            }
        }

        // Replace @yield('name'[, default]) with the page's section content,
        // tolerating whitespace. Yields without a matching section keep their
        // default via the pass below, then Phase 1 strips bare leftovers.
        for (name, content) in sections {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let yieldRegex = try? NSRegularExpression(
                pattern: #"@yield\s*\(\s*['"]"# + escaped + #"['"]\s*(?:,[^)]*)?\)"#,
                options: []
            ) else { continue }
            let nsComposed = composed as NSString
            let matches = yieldRegex.matches(
                in: composed, options: [],
                range: NSRange(location: 0, length: nsComposed.length)
            )
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: composed) else { continue }
                composed.replaceSubrange(fullRange, with: content)
            }
        }

        // Remaining @yield('name', 'default') → default value
        if let yieldDefaultRegex = try? NSRegularExpression(
            pattern: #"@yield\s*\(\s*['"][^'"]*['"]\s*,\s*['"]([^'"]*)['"]\s*\)"#,
            options: []
        ) {
            let nsComposed = composed as NSString
            let matches = yieldDefaultRegex.matches(
                in: composed, options: [],
                range: NSRange(location: 0, length: nsComposed.length)
            )
            for match in matches.reversed() {
                guard let defaultRange = Range(match.range(at: 1), in: composed),
                      let fullRange = Range(match.range, in: composed) else { continue }
                let defaultValue = String(composed[defaultRange])
                composed.replaceSubrange(fullRange, with: defaultValue)
            }
        }

        return composed
    }

    // MARK: - Parse Props from HTML Attributes

    /// Parses `key="value"` attributes into props. Strips Blade's `:` expression-binding prefix
    /// from keys and converts kebab-case to camelCase.
    ///
    /// A `:`-bound prop's raw attribute text is PHP source, not literal HTML text — e.g.
    /// `:status="session('status')"`. Only when that source resolves to a static literal
    /// (a quoted string or a `__('...')` call, via `resolveLiteralExpression`) is it safe to
    /// substitute; any other dynamic expression (a function call, variable, concatenation)
    /// substitutes as an EMPTY STRING instead, so raw PHP source can't leak into the preview
    /// at the shared echo-substitution sites (`composeInlineComponent`'s and `composeLayout`'s
    /// prop passes both just echo whatever this dict holds, so resolving it centrally here
    /// keeps both call sites consistent without touching either). A static (non-`:`) attribute
    /// value is always literal HTML text and is never emptied.
    private static func parseProps(from attrsString: String) -> [String: String] {
        var props: [String: String] = [:]

        // Group 1: leading `:` (dynamic bind). Accept both double- and single-quoted values
        // (group 3 = "…", group 4 = '…').
        guard let regex = try? NSRegularExpression(
            pattern: #"(:)?([\w\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
            options: []
        ) else { return props }

        let nsString = attrsString as NSString
        let matches = regex.matches(
            in: attrsString, options: [],
            range: NSRange(location: 0, length: nsString.length)
        )

        for match in matches {
            guard let keyRange = Range(match.range(at: 2), in: attrsString) else { continue }
            let key = String(attrsString[keyRange])
            let isDynamic = match.range(at: 1).location != NSNotFound

            let value: String
            if match.range(at: 3).location != NSNotFound, let r = Range(match.range(at: 3), in: attrsString) {
                value = String(attrsString[r])
            } else if match.range(at: 4).location != NSNotFound, let r = Range(match.range(at: 4), in: attrsString) {
                value = String(attrsString[r])
            } else {
                continue
            }

            let propName = kebabToCamelCase(key)
            if isDynamic {
                props[propName] = resolveLiteralExpression(value) ?? ""
            } else {
                // A static `value="__('Username')"` bind's raw text is the literal call, not
                // the translated text — resolve it here so echo substitution below (`{{
                // $value ?? … }}`) inserts "Username", not the raw `__('Username')` call.
                // Non-translation values (including plain literals) pass through unchanged.
                props[propName] = translationLiteralText(value) ?? value
            }
        }

        return props
    }


    private static func stripPropsDeclaration(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"@props\s*\(\s*\[[\s\S]*?\]\s*\)"#,
            options: []
        ) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: "")
    }

    // MARK: - @php Static Evaluation
    //
    // Real Blade runs component @php blocks through PHP. This is a STATIC approximation
    // covering the two assignment shapes that put layout-critical values into echoes
    // (padding classes, icon markup): string literals with `.` concatenation, and `match`
    // expressions over an already-known scalar (a caller prop, an @props default, or an
    // earlier assignment in the same block). Anything else is left unevaluated — the
    // unresolved echo falls through to BladeTranspiler Phase 3 exactly as before.

    /// Parses `@props(['size' => 'lg', ...])` defaults. Keys declared without a default
    /// (`'slug'`) and non-literal defaults are skipped.
    private static func parsePropsDefaults(_ source: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"@props\s*\(\s*(\[[\s\S]*?\])\s*\)"#,
            options: []
        ) else { return [:] }
        let ns = source as NSString
        guard let match = regex.firstMatch(in: source, options: [], range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound else { return [:] }
        var defaults: [String: String] = [:]
        for (key, value) in parseArrayLiteralPairs(ns.substring(with: match.range(at: 1))) {
            defaults[key] = value
        }
        return defaults
    }

    private static let phpScalarToken = #"(?:'[^']*'|"[^"]*"|\$\w+)"#
    private static let phpConcatExpr = phpScalarToken + #"(?:\s*\.\s*"# + phpScalarToken + #")*"#

    /// Statically evaluates simple `$var = ...;` assignments inside `@php ... @endphp`
    /// blocks, in source order (each resolved variable joins the scope available to later
    /// assignments). Returns only the variables that fully resolved.
    private static func evaluatePhpAssignments(in source: String, scope initialScope: [String: String]) -> [String: String] {
        guard let blockRegex = try? NSRegularExpression(pattern: #"@php([\s\S]*?)@endphp"#, options: []),
              // The `;` terminator is load-bearing: a partial concat match ('a' . fn())
              // can't satisfy it, so partially-evaluable expressions stay unresolved
              // instead of silently truncating.
              let simpleRegex = try? NSRegularExpression(
                pattern: #"\$(\w+)\s*=\s*("# + phpConcatExpr + #")\s*;"#, options: []),
              let matchHeadRegex = try? NSRegularExpression(
                pattern: #"\$(\w+)\s*=\s*match\s*\(\s*("# + phpScalarToken + #")\s*\)\s*\{"#, options: [])
        else { return [:] }

        enum Assignment {
            case simple(name: String, expr: String)
            case matchExpr(name: String, subject: String, armsBody: String)
        }

        let ns = source as NSString
        var scope = initialScope
        var resolved: [String: String] = [:]

        for block in blockRegex.matches(in: source, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard block.range(at: 1).location != NSNotFound else { continue }
            let body = ns.substring(with: block.range(at: 1))
            let bodyNS = body as NSString
            let bodyRange = NSRange(location: 0, length: bodyNS.length)

            var found: [(location: Int, assignment: Assignment)] = []
            for m in simpleRegex.matches(in: body, options: [], range: bodyRange) {
                guard m.range(at: 1).location != NSNotFound, m.range(at: 2).location != NSNotFound else { continue }
                found.append((m.range.location, .simple(
                    name: bodyNS.substring(with: m.range(at: 1)),
                    expr: bodyNS.substring(with: m.range(at: 2)))))
            }
            for m in matchHeadRegex.matches(in: body, options: [], range: bodyRange) {
                guard m.range(at: 1).location != NSNotFound, m.range(at: 2).location != NSNotFound,
                      let armsBody = balancedBraceBody(in: body, afterUTF16Offset: m.range.location + m.range.length)
                else { continue }
                found.append((m.range.location, .matchExpr(
                    name: bodyNS.substring(with: m.range(at: 1)),
                    subject: bodyNS.substring(with: m.range(at: 2)),
                    armsBody: armsBody)))
            }
            found.sort { $0.location < $1.location }

            for (_, assignment) in found {
                switch assignment {
                case .simple(let name, let expr):
                    guard let value = evaluateConcat(expr, scope: scope) else { continue }
                    scope[name] = value
                    resolved[name] = value
                case .matchExpr(let name, let subject, let armsBody):
                    guard let subjectValue = resolveScalarToken(subject, scope: scope),
                          let value = evaluateMatchArms(armsBody, subject: subjectValue, scope: scope)
                    else { continue }
                    scope[name] = value
                    resolved[name] = value
                }
            }
        }
        return resolved
    }

    /// Returns the text between an already-consumed `{` and its matching `}`, honoring
    /// single/double-quoted runs so braces inside string literals don't count.
    private static func balancedBraceBody(in text: String, afterUTF16Offset offset: Int) -> String? {
        let ns = text as NSString
        var depth = 1
        var quote: unichar? = nil
        var i = offset
        while i < ns.length {
            let c = ns.character(at: i)
            if let q = quote {
                if c == q { quote = nil }
            } else {
                switch c {
                case 0x27, 0x22: quote = c        // ' or "
                case 0x7B: depth += 1             // {
                case 0x7D:                        // }
                    depth -= 1
                    if depth == 0 {
                        return ns.substring(with: NSRange(location: offset, length: i - offset))
                    }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    /// Evaluates a `.`-concatenation of string literals and scope variables; nil when any
    /// piece is a variable the scope doesn't hold.
    private static func evaluateConcat(_ expr: String, scope: [String: String]) -> String? {
        guard let tokenRegex = try? NSRegularExpression(pattern: #"'([^']*)'|"([^"]*)"|\$(\w+)"#, options: [])
        else { return nil }
        let ns = expr as NSString
        var out = ""
        for m in tokenRegex.matches(in: expr, options: [], range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                out += ns.substring(with: m.range(at: 1))
            } else if m.range(at: 2).location != NSNotFound {
                out += ns.substring(with: m.range(at: 2))
            } else if m.range(at: 3).location != NSNotFound {
                guard let value = scope[ns.substring(with: m.range(at: 3))] else { return nil }
                out += value
            }
        }
        return out
    }

    /// Resolves a match subject token — `$var` from scope, or a quoted literal.
    private static func resolveScalarToken(_ raw: String, scope: [String: String]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$") { return scope[String(trimmed.dropFirst())] }
        return resolveLiteralExpression(trimmed)
    }

    /// Picks the arm whose key list contains `subject` (falling back to the `default` arm)
    /// and evaluates its value expression against the scope. The `(?=\s*(?:,|\z))` lookahead
    /// rejects arms whose value only PARTIALLY matches the concat shape (e.g. `'a' . fn()`) —
    /// those stay unresolved rather than truncating.
    private static func evaluateMatchArms(_ body: String, subject: String, scope: [String: String]) -> String? {
        let keyList = #"(default|(?:'[^']*'|"[^"]*")(?:\s*,\s*(?:'[^']*'|"[^"]*"))*)"#
        guard let armRegex = try? NSRegularExpression(
            pattern: keyList + #"\s*=>\s*("# + phpConcatExpr + #")(?=\s*(?:,|\z))"#,
            options: []
        ) else { return nil }
        let ns = body as NSString
        var defaultExpr: String?
        for m in armRegex.matches(in: body, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard m.range(at: 1).location != NSNotFound, m.range(at: 2).location != NSNotFound else { continue }
            let keys = ns.substring(with: m.range(at: 1))
            let valueExpr = ns.substring(with: m.range(at: 2))
            if keys == "default" {
                defaultExpr = valueExpr
                continue
            }
            if parseKeyList(keys).contains(subject) {
                return evaluateConcat(valueExpr, scope: scope)
            }
        }
        guard let defaultExpr else { return nil }
        return evaluateConcat(defaultExpr, scope: scope)
    }

    private static func kebabToCamelCase(_ string: String) -> String {
        let parts = string.split(separator: "-")
        guard let first = parts.first else { return string }
        let rest = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return String(first) + rest.joined()
    }

    // MARK: - Extract Slots

    /// Extracts named `<x-slot>` blocks from `content`, leaving everything else as the
    /// default slot. Only slots at DEPTH 0 relative to `content` are claimed — one nested
    /// inside another, still-unresolved `<x-name>...</x-name>` tag belongs to THAT
    /// component, not to the caller. Without this, e.g. `resolveComponentLayout` scanning
    /// a whole page body would steal `<x-auth-card><x-slot name="heading">…</x-slot>…
    /// </x-auth-card>`'s heading slot for the outer layout (which has no matching echo,
    /// so it's silently discarded) before `<x-auth-card>` itself ever gets a chance to
    /// claim it, leaving its own `{{ $heading }}` echo unfilled.
    private static func extractSlots(from content: String) -> (named: [String: String], defaultSlot: String) {
        var namedSlots: [String: String] = [:]

        // ONE tokenizer pass over the content, then a single left-to-right walk of
        // the resulting token list. An earlier version re-ran a full
        // open+body+close regex over the whole REMAINING document once per slot
        // token, which made a page of unclosed `<x-slot>` tags cost O(n^3) — 16KB
        // of them took 33 seconds. Pairing opens to closes from the token stream
        // instead keeps the whole function linear.
        //
        // Groups: 1 = slot open tag, 2/3 = its name (`:name` and `name="…"` forms),
        // 4 = other self-closing, 5 = other paired open, 6 = other paired close,
        // 7 = slot close. `(?!slot\b)` keeps slot tags out of the "other" groups.
        let quotedAttrs = quotedAttrRun
        guard let tokenRegex = try? NSRegularExpression(
            pattern: #"(<x-slot(?::([\w-]+)|\s+name\s*=\s*["']([\w-]+)["'])[^>]*>)"#
                + #"|(<x-(?!slot\b)[\w\-\.:]+(?:\s"# + quotedAttrs + #")?\s*/>)"#
                + #"|(<x-(?!slot\b)[\w\-\.:]+(?:\s"# + quotedAttrs + #")?(?<!/)>)"#
                + #"|(</x-(?!slot\b)[\w\-\.:]+>)"#
                + #"|(</x-slot(?::[\w-]+)?\s*>)"#,
            options: []
        ) else { return (namedSlots, content) }

        let ns = content as NSString
        let tokens = tokenRegex.matches(
            in: content, options: [], range: NSRange(location: 0, length: ns.length))
        guard !tokens.isEmpty else { return (namedSlots, content) }

        var otherDepth = 0
        var slotRanges: [Range<String.Index>] = []
        // Once a look-ahead finds no closing tag, no LATER open can find one either
        // (they all start further right), so stop looking. Without this, a document
        // full of unclosed slots would still be quadratic in token count.
        var closerExhausted = false
        var i = 0

        while i < tokens.count {
            let m = tokens[i]

            if m.range(at: 1).location != NSNotFound {
                // A <x-slot> open tag. Only claim it at depth 0 — nested inside
                // another unresolved component, it isn't ours.
                var closeIndex: Int? = nil
                if otherDepth == 0 && !closerExhausted {
                    // Pair with the FIRST following close tag, matching the lazy
                    // `[\s\S]*?` this replaced. Names aren't required to agree.
                    var j = i + 1
                    while j < tokens.count {
                        if tokens[j].range(at: 7).location != NSNotFound { closeIndex = j; break }
                        j += 1
                    }
                    if closeIndex == nil { closerExhausted = true }
                }

                if let closeIndex {
                    let close = tokens[closeIndex]
                    let bodyStart = m.range.location + m.range.length
                    let bodyRange = NSRange(location: bodyStart, length: close.range.location - bodyStart)
                    let wholeRange = NSRange(
                        location: m.range.location,
                        length: close.range.location + close.range.length - m.range.location)
                    let nameNSRange = m.range(at: 2).location != NSNotFound
                        ? m.range(at: 2) : m.range(at: 3)
                    if let nameRange = Range(nameNSRange, in: content),
                       let valueRange = Range(bodyRange, in: content),
                       let fullRange = Range(wholeRange, in: content) {
                        namedSlots[String(content[nameRange])] = String(content[valueRange])
                        slotRanges.append(fullRange)
                    }
                    // Skip the body's tokens entirely — they belong to this slot,
                    // not to the surrounding nesting count.
                    i = closeIndex + 1
                    continue
                }
                // Nested inside another component (or malformed/unclosed): leave
                // it for that component's own extractSlots call to claim.
            } else if m.range(at: 4).location != NSNotFound {
                // Other self-closing component: doesn't nest, no depth change.
            } else if m.range(at: 5).location != NSNotFound {
                // Other paired open: entering a nested component.
                otherDepth += 1
            } else if m.range(at: 6).location != NSNotFound {
                // Other paired close: leaving a nested component.
                otherDepth = max(0, otherDepth - 1)
            }
            // Group 7 (a stray slot close with no open we claimed) changes nothing,
            // exactly as before — the old tokenizer didn't recognise it at all.
            i += 1
        }

        var defaultContent = content
        for range in slotRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            defaultContent.removeSubrange(range)
        }

        return (namedSlots, defaultContent)
    }

    // MARK: - Extract Sections (for @extends)

    private static func extractSections(from source: String) -> [String: String] {
        var sections: [String: String] = [:]

        // Multi-line: @section('name') ... @endsection
        if let regex = try? NSRegularExpression(
            pattern: #"@section\s*\(\s*['"]([^'"]*)['"]\s*\)\s*([\s\S]*?)@(?:endsection|stop|append|overwrite)(?!\w)"#,
            options: []
        ) {
            let nsSource = source as NSString
            let matches = regex.matches(
                in: source, options: [],
                range: NSRange(location: 0, length: nsSource.length)
            )
            for match in matches {
                guard let nameRange = Range(match.range(at: 1), in: source),
                      let contentRange = Range(match.range(at: 2), in: source) else { continue }
                sections[String(source[nameRange])] = String(source[contentRange])
            }
        }

        // Inline: @section('name', 'value')
        if let regex = try? NSRegularExpression(
            pattern: #"@section\s*\(\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*\)"#,
            options: []
        ) {
            let nsSource = source as NSString
            let matches = regex.matches(
                in: source, options: [],
                range: NSRange(location: 0, length: nsSource.length)
            )
            for match in matches {
                guard let nameRange = Range(match.range(at: 1), in: source),
                      let valueRange = Range(match.range(at: 2), in: source) else { continue }
                sections[String(source[nameRange])] = String(source[valueRange])
            }
        }

        return sections
    }

    // MARK: - Compose Layout

    /// Replaces every `{{ $name }}` echo of one variable, tolerating internal
    /// whitespace and an optional `?? fallback` tail: `{{$title}}`,
    /// `{{ $title ?? 'Default' }}`, `{{ $header ?? '' }}` all match.
    /// The replacement is inserted literally (template-escaped), so slot HTML
    /// containing `$` can't corrupt the substitution.
    private static func replaceEcho(of name: String, in source: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\{\{\s*\$"# + escaped + #"\s*(?:\?\?[^}]*)?\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source, options: [], range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// `{!! $name !!}` counterpart of replaceEcho, for raw echoes whose value is HTML
    /// that must land unescaped (e.g. a @php-computed `$svg`).
    private static func replaceRawEcho(of name: String, in source: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\{!!\s*\$"# + escaped + #"\s*(?:\?\?[^}]*)?!!\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source, options: [], range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Shared tail of both compose paths: substitutes @php-computed variables (raw and
    /// escaped echoes), caller props, and — for props the caller didn't pass — @props
    /// defaults, in that order.
    private static func substituteComputedAndProps(
        in composed: String,
        phpVars: [String: String],
        props: [String: String],
        propDefaults: [String: String]
    ) -> String {
        var result = composed
        for (name, value) in phpVars {
            result = replaceRawEcho(of: name, in: result, with: value)
            result = replaceEcho(of: name, in: result, with: DefaultStylesheet.escapeHTML(value))
        }
        for (name, value) in props {
            result = replaceEcho(of: name, in: result, with: DefaultStylesheet.escapeHTML(value))
        }
        for (name, value) in propDefaults where props[name] == nil {
            result = replaceEcho(of: name, in: result, with: DefaultStylesheet.escapeHTML(value))
        }
        return result
    }

    private static func composeLayout(
        layout: String,
        defaultSlot: String,
        namedSlots: [String: String],
        props: [String: String]
    ) -> String {
        let propDefaults = parsePropsDefaults(layout)
        var result = stripPropsDeclaration(layout)

        // @php evaluation scope: @props defaults overridden by caller props.
        var scope = propDefaults
        for (key, value) in props { scope[key] = value }
        let phpVars = evaluatePhpAssignments(in: result, scope: scope)

        // Default slot, then named slots, then computed vars and props — all
        // whitespace-tolerant, and a bare `{{ $header }}` (no `?? ''`) now
        // receives its slot too.
        result = replaceEcho(of: "slot", in: result, with: defaultSlot)
        for (name, content) in namedSlots {
            result = replaceEcho(of: name, in: result, with: content)
        }
        return substituteComputedAndProps(
            in: result, phpVars: phpVars, props: props, propDefaults: propDefaults)
    }

    // MARK: - Find Compiled CSS

    private static let maxTotalCSS = 8 * 1024 * 1024 // 8MB guard on total inlined CSS

    private static func findCompiledCSS(projectRoot: URL) -> String? {
        let assetsDir = projectRoot
            .appendingPathComponent("public")
            .appendingPathComponent("build")
            .appendingPathComponent("assets")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: assetsDir, includingPropertiesForKeys: nil
        ) else {
            logger.info("No build/assets directory found")
            return nil
        }

        // Alphabetical for a deterministic cascade; per-file size check BEFORE
        // reading so one giant file can neither blow memory nor bypass the cap.
        let cssFiles = files.filter { $0.pathExtension == "css" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var allCSS = ""
        var totalBytes = 0
        var inlinedCount = 0
        for cssFile in cssFiles {
            let size = (try? cssFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard totalBytes + size <= maxTotalCSS else {
                logger.info("Skipping \(cssFile.lastPathComponent): would exceed CSS cap (\(maxTotalCSS) bytes)")
                continue
            }
            if let css = try? String(contentsOf: cssFile, encoding: .utf8) {
                allCSS += css + "\n"
                totalBytes += css.utf8.count + 1
                inlinedCount += 1
            }
        }

        if !allCSS.isEmpty {
            logger.info("Inlined \(inlinedCount) CSS file(s)")
        }
        return allCSS.isEmpty ? nil : allCSS
    }

    // MARK: - Inline Assets

    private static let fontMimeTypes: [String: String] = [
        "ttf": "font/ttf",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "otf": "font/otf",
    ]

    private static let maxFontSize = 2 * 1024 * 1024 // 2MB

    /// Inlines local `url()` references (fonts, background images) in CSS as data URIs.
    private static func inlineCSSResources(_ css: String, projectRoot: URL) -> String {
        // Any root-relative url(/…) resolves against public/ — /build/assets,
        // /fonts, /images alike. Optional quotes. data:/http(s):/relative urls
        // don't start with "/" and are skipped; //protocol-relative resolves to
        // a nonexistent public// path and is skipped by the file read below.
        guard let urlRegex = try? NSRegularExpression(
            pattern: #"url\(\s*['"]?(/[^'")]+)['"]?\s*\)"#,
            options: []
        ) else { return css }

        let nsCSS = css as NSString
        let matches = urlRegex.matches(
            in: css, options: [],
            range: NSRange(location: 0, length: nsCSS.length)
        )

        guard !matches.isEmpty else { return css }

        var result = css
        var inlinedCount = 0

        for match in matches.reversed() {
            guard let pathRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }

            let urlPath = String(result[pathRange])
            let trimmed = urlPath.hasPrefix("/") ? String(urlPath.dropFirst()) : urlPath
            // Stylesheet text is untrusted (a hostile project supplies its own
            // compiled CSS), so the url() target must stay inside public/.
            guard let fileURL = containedURL(
                trimmed, under: projectRoot.appendingPathComponent("public"),
                projectRoot: projectRoot) else {
                logger.info("Skipping CSS url() that resolves outside public/")
                continue
            }

            let ext = (trimmed as NSString).pathExtension.lowercased()
            let mime: String
            if let fontMime = fontMimeTypes[ext] {
                mime = fontMime
            } else if let imgMime = mimeTypes[ext] {
                mime = imgMime
            } else {
                continue
            }

            // Stat before reading: a giant referenced asset must not be pulled
            // into memory just to be discarded (mirrors inlineImages).
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard fileSize > 0, fileSize <= maxFontSize,
                  let data = try? Data(contentsOf: fileURL) else { continue }

            let base64 = data.base64EncodedString()
            let dataURI = "url(data:\(mime);base64,\(base64))"
            result.replaceSubrange(fullRange, with: dataURI)
            inlinedCount += 1
        }

        if inlinedCount > 0 {
            logger.info("Inlined \(inlinedCount) CSS resource(s) (fonts/images)")
        }
        return result
    }

    // MARK: - FontAwesome inlining

    private static let maxFontFile = 3 * 1024 * 1024 // 3MB per webfont

    /// If the HTML uses FontAwesome icons and FA assets exist locally, returns CSS (@font-face +
    /// icon definitions) with the webfonts inlined as data URIs. Many Laravel/Flux apps load FA
    /// from an external CDN or object-storage URL that Quick Look can't fetch offline, but the
    /// same files are usually synced locally — so icons can render.
    private static func inlineFontAwesome(in html: String, projectRoot: URL) -> String {
        // Only worth the weight if the page actually uses FA icon classes.
        guard html.range(of: #"class\s*=\s*['"][^'"]*(?:\bfa[srbl]?\b|\bfa-[a-z0-9-]+)"#,
                         options: .regularExpression) != nil else { return "" }

        let fm = FileManager.default
        let candidates = [
            "storage/assets/fonts/css", "public/fonts/css", "public/fonts",
            "public/vendor/fontawesome/css", "node_modules/@fortawesome/fontawesome-free/css",
        ]
        var cssDir: URL?
        for c in candidates {
            let dir = projectRoot.appendingPathComponent(c)
            if fm.fileExists(atPath: dir.appendingPathComponent("fontawesome.min.css").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("all.min.css").path) {
                cssDir = dir
                break
            }
        }
        guard let cssDir = cssDir else { return "" }

        // Pick a NON-overlapping set: `all.min.css` is self-contained (core + every @font-face),
        // so reading it AND the per-style files would inline each webfont twice. Prefer it; only
        // fall back to the split files when there's no all-in-one build.
        func has(_ n: String) -> Bool { fm.fileExists(atPath: cssDir.appendingPathComponent(n).path) }
        var names: [String]
        if has("all.min.css") {
            names = ["all.min.css"]
            if has("custom-icons.min.css") { names.append("custom-icons.min.css") }
        } else {
            names = ["fontawesome.min.css", "solid.min.css", "regular.min.css",
                     "brands.min.css", "custom-icons.min.css"]
        }
        var combined = ""
        for name in names {
            if let s = try? String(contentsOf: cssDir.appendingPathComponent(name), encoding: .utf8) {
                combined += s + "\n"
            }
        }
        guard !combined.isEmpty else { return "" }

        logger.info("Inlining local FontAwesome from \(cssDir.path)")
        return inlineFontURLs(combined, relativeTo: cssDir, within: projectRoot)
    }

    /// Rewrites `url(...woff2|woff|ttf...)` references in a stylesheet to base64 data URIs,
    /// resolving relative paths against the stylesheet's own directory and requiring the
    /// result to stay inside the project.
    ///
    /// The boundary is `projectRoot`, not `cssDir`: FontAwesome's own layout puts its
    /// webfonts in a SIBLING of the stylesheet directory (`css/all.min.css` references
    /// `../webfonts/fa.woff2`), so containing to `cssDir` would reject every real
    /// FontAwesome install. Project-level containment still stops a `..` climb from
    /// reaching the rest of the home folder, which is the actual risk.
    private static func inlineFontURLs(
        _ css: String, relativeTo cssDir: URL, within projectRoot: URL
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"url\(\s*['"]?([^'")]+\.(?:woff2?|ttf|otf))[^'")]*['"]?\s*\)"#,
            options: []
        ) else { return css }

        let nsCSS = css as NSString
        let matches = regex.matches(in: css, options: [], range: NSRange(location: 0, length: nsCSS.length))
        guard !matches.isEmpty else { return css }

        var result = css
        var inlined = 0
        for match in matches.reversed() {
            guard let pathRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let rel = String(result[pathRange])
            // Resolved against the stylesheet's own directory, then checked against the
            // project boundary — this join standardizes the path, so an unchecked `..`
            // would climb straight out of the project.
            guard let fileURL = contain(cssDir.appendingPathComponent(rel),
                                        within: projectRoot, projectRoot: projectRoot) else {
                logger.info("Skipping webfont url() that resolves outside the project")
                continue
            }
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard fileSize > 0, fileSize <= maxFontFile,
                  let data = try? Data(contentsOf: fileURL) else { continue }
            let ext = (rel as NSString).pathExtension.lowercased()
            let mime = fontMimeTypes[ext] ?? "font/woff2"
            result.replaceSubrange(fullRange, with: "url(data:\(mime);base64,\(data.base64EncodedString()))")
            inlined += 1
        }
        if inlined > 0 { logger.info("Inlined \(inlined) FontAwesome webfont(s)") }
        return result
    }

    private static func inlineAssets(_ html: String, css: String?, projectRoot: URL) -> String {
        var result = html

        // Replace first @vite(...) with inlined <style>, strip the rest
        if let viteRegex = try? NSRegularExpression(
            pattern: #"@vite\s*"# + balancedParens,
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = viteRegex.matches(in: result, options: [], range: range)

            if !matches.isEmpty {
                // Alpine.js elements with x-show start hidden (JS toggles them).
                // Without JS, hide them so the preview matches the initial page state.
                let jsFrameworkDefaults = "[x-show] { display: none !important; }\n[x-cloak] { display: none !important; }\n"
                    + "[wire\\:loading],[wire\\:loading\\.flex],[wire\\:loading\\.block],[wire\\:loading\\.inline],[wire\\:loading\\.inline-flex],[wire\\:loading\\.grid],[wire\\:loading\\.table],[wire\\:loading\\.delay]{display:none!important}\n"
                    + DefaultStylesheet.fluxShimCSS

                let faCSS = inlineFontAwesome(in: result, projectRoot: projectRoot)
                let replacement: String
                if let css = css {
                    let inlinedCSS = inlineCSSResources(css, projectRoot: projectRoot)
                    let darkModeBridge = buildDarkModeBridge(from: css)
                    replacement = "<style>\n\(inlinedCSS)\n\(darkModeBridge)\n\(faCSS)\n\(jsFrameworkDefaults)\n</style>"
                } else {
                    replacement = "<style>\n\(faCSS)\n\(jsFrameworkDefaults)\n</style>"
                }

                // Replace in reverse: first match gets CSS, rest get stripped
                for (i, match) in matches.enumerated().reversed() {
                    guard let matchRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(matchRange, with: i == 0 ? replacement : "")
                }
            }
        }

        // Strip external <script> tags (analytics, CDN scripts — not useful in preview)
        if let scriptRegex = try? NSRegularExpression(
            pattern: #"<script\b[^>]*\bsrc\s*=[^>]*>[\s\S]*?</script>"#,
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = scriptRegex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: ""
            )
        }

        // Strip external <link rel="stylesheet"> tags (CDN fonts/icons won't load in Quick Look)
        if let linkRegex = try? NSRegularExpression(
            pattern: #"<link[^>]*rel\s*=\s*"stylesheet"[^>]*href\s*=\s*"https?://[^>]*>"#,
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = linkRegex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: ""
            )
        }
        // Also catch <link href="https://..." rel="stylesheet"> (reversed attribute order)
        if let linkRegex2 = try? NSRegularExpression(
            pattern: #"<link[^>]*href\s*=\s*"https?://[^>]*rel\s*=\s*"stylesheet"[^>]*>"#,
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = linkRegex2.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: ""
            )
        }
        // Strip preconnect links (font CDNs, DNS prefetch)
        if let preconnectRegex = try? NSRegularExpression(
            pattern: #"<link[^>]*(?:preconnect|dns-prefetch)[^>]*>"#,
            options: []
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = preconnectRegex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: ""
            )
        }

        return result
    }

    // MARK: - Resolve Asset Echoes

    /// Rewrites static `{{ asset('…') }}` / `{{ url('…') }}` / `{{ secure_asset('…') }}`
    /// echoes to root-relative paths so inlineImages/inlineCSSResources can resolve
    /// them against public/. Dynamic expressions (concatenation, variables) are left
    /// for the transpiler to strip as usual.
    private static func resolveAssetEchoes(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{\s*(?:secure_)?(?:asset|url)\(\s*['"]([^'"]+)['"]\s*\)\s*\}\}"#,
            options: []
        ) else { return html }

        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html, options: [],
            range: NSRange(location: 0, length: nsHTML.length)
        )
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            guard let pathRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            var path = String(result[pathRange])
            // Absolute URLs (url('https://…')) are runtime values, not local
            // paths — leave the echo for Phase 3's placeholder handling.
            if path.contains("://") { continue }
            if !path.hasPrefix("/") { path = "/" + path }
            result.replaceSubrange(fullRange, with: path)
        }
        return result
    }

    // MARK: - Inline Images

    private static let maxImageSize = 500 * 1024 // 500KB
    private static let maxImageDimension = 1600
    private static let maxSourceImageSize = 20 * 1024 * 1024 // never read >20MB into memory

    /// Downscales an oversized raster image to maxImageDimension and re-encodes
    /// as JPEG so big hero images still preview instead of silently vanishing.
    private static func downscaledJPEG(_ data: Data) -> Data? {
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static let mimeTypes: [String: String] = [
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "ico": "image/x-icon",
        "webp": "image/webp",
    ]

    private static func inlineImages(_ html: String, projectRoot: URL) -> String {
        // Group 1: double-quoted src value; group 2: single-quoted.
        guard let imgRegex = try? NSRegularExpression(
            pattern: #"<img[^>]+src\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
            options: []
        ) else { return html }

        let nsHTML = html as NSString
        let matches = imgRegex.matches(
            in: html, options: [],
            range: NSRange(location: 0, length: nsHTML.length)
        )

        var result = html
        var inlinedCount = 0

        // Process in reverse so replacements don't shift ranges
        for match in matches.reversed() {
            let srcNSRange = match.range(at: 1).location != NSNotFound
                ? match.range(at: 1) : match.range(at: 2)
            guard let srcRange = Range(srcNSRange, in: result) else { continue }
            let src = String(result[srcRange])

            // Skip external and data URLs
            if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("data:") {
                continue
            }

            // Resolve relative to public/, and require it to stay there. The src
            // value comes from the previewed file, which is untrusted.
            let trimmed = src.hasPrefix("/") ? String(src.dropFirst()) : src
            guard let imageURL = containedURL(
                trimmed, under: projectRoot.appendingPathComponent("public"),
                projectRoot: projectRoot) else {
                logger.info("Skipping <img src> that resolves outside public/")
                continue
            }

            let fileSize = (try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard fileSize > 0, fileSize <= maxSourceImageSize,
                  let data = try? Data(contentsOf: imageURL) else { continue }

            let ext = (trimmed as NSString).pathExtension.lowercased()
            guard var mime = mimeTypes[ext] else { continue }

            var payload = data
            if data.count > maxImageSize {
                // SVG is text and GIF may animate — no meaningful downscale; skip as before.
                guard ext != "svg", ext != "gif",
                      let scaled = downscaledJPEG(data), scaled.count < data.count else {
                    logger.info("Skipping large image (\(data.count) bytes): \(trimmed)")
                    continue
                }
                payload = scaled
                mime = "image/jpeg"
                logger.info("Downscaled large image (\(data.count) → \(scaled.count) bytes): \(trimmed)")
            }

            let dataURI = "data:\(mime);base64,\(payload.base64EncodedString())"
            result = result.replacingCharacters(in: srcRange, with: dataURI)
            inlinedCount += 1
        }

        if inlinedCount > 0 {
            logger.info("Inlined \(inlinedCount) image(s)")
        }
        return result
    }

    // MARK: - Dark Mode Bridge
    //
    // The compiled CSS uses [data-theme=dark] for dark mode (JS toggle).
    // Quick Look may not execute JS, so we bridge it with @media queries.

    private static func buildDarkModeBridge(from css: String) -> String {
        guard let darkRegex = try? NSRegularExpression(
            pattern: #"\[data-theme=dark\]\s*\{([^}]*)\}"#,
            options: []
        ) else { return "" }

        let nsCSS = css as NSString
        let matches = darkRegex.matches(
            in: css, options: [],
            range: NSRange(location: 0, length: nsCSS.length)
        )
        guard !matches.isEmpty else { return "" }

        // The pattern matches only a bare `[data-theme=dark] { … }` block (selector
        // immediately followed by `{`) — flat variable declarations — so every such
        // block can be folded into :root. Compiled CSS often has more than one.
        let varsContent = matches
            .map { nsCSS.substring(with: $0.range(at: 1)) }
            .joined(separator: "\n")

        return """
        @media (prefers-color-scheme: dark) {
            :root { \(varsContent) }
        }
        """
    }
}
