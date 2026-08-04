import Foundation

/// User-facing footer explaining WHY a preview degraded. Only real failures get
/// a strip — the normal fallbacks (no Laravel root, no layout directive) stay
/// silent by design. Pure Foundation so the unit-test target can build it.
struct DiagnosticsStrip {

    static func message(for diagnostics: TemplateResolver.Diagnostics) -> String? {
        if diagnostics.readDenied {
            return "Quick Blade couldn't read files in this project — macOS privacy "
                + "protection may be blocking the folder. Allow access in System Settings "
                + "> Privacy & Security > Files and Folders > Quick Blade, or keep projects "
                + "in a folder like ~/Herd, ~/Sites, or ~/Developer."
        }
        if diagnostics.layoutMissing {
            return "This file references a layout that wasn't found, so it's shown standalone."
        }
        return nil
    }

    /// Inserts the strip before </body> when present, else appends. The strip
    /// carries its own style block (dark-mode aware) and pads the page bottom
    /// so it never covers content.
    static func inject(into html: String, message: String) -> String {
        let block = """
        <style>
        body { padding-bottom: 3.5rem !important; }
        .qb-diagnostics {
            position: fixed; left: 0; right: 0; bottom: 0; z-index: 9999;
            padding: 8px 16px; box-sizing: border-box;
            font: 12px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
            background: rgba(255, 249, 196, 0.96); color: #5f4b00;
            border-top: 1px solid rgba(0, 0, 0, 0.15);
        }
        @media (prefers-color-scheme: dark) {
            .qb-diagnostics {
                background: rgba(66, 60, 22, 0.96); color: #e8d98a;
                border-top-color: rgba(255, 255, 255, 0.15);
            }
        }
        </style>
        <div class="qb-diagnostics">\(DefaultStylesheet.escapeHTML(message))</div>
        """
        if let range = html.range(of: "</body>", options: .caseInsensitive) {
            var result = html
            result.replaceSubrange(range.lowerBound..<range.lowerBound, with: block)
            return result
        }
        return html + block
    }
}
