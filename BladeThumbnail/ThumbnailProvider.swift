import QuickLookThumbnailing
import AppKit

/// Draws a code-card thumbnail for .blade.php files: white card, the first
/// lines of source in monospace, a purple "blade" badge. Plain CoreGraphics /
/// AppKit string drawing — deliberately NO WebKit (blocked in extension
/// sandboxes, FINDINGS §3) and NO NSAttributedString(html:) (also WebKit).
class ThumbnailProvider: QLThumbnailProvider {

    enum ThumbnailError: Error {
        case notBlade
    }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // We claim all of public.php-script; decline plain PHP so the system's
        // normal icon/providers keep those files.
        guard request.fileURL.lastPathComponent.lowercased().hasSuffix(".blade.php") else {
            handler(nil, ThumbnailError.notBlade)
            return
        }
        let source = (try? String(contentsOf: request.fileURL, encoding: .utf8)) ?? ""
        let lines = Self.snippetLines(from: source)
        let size = request.maximumSize
        // Use the raw-CGContext initializer, not currentContextDrawing: Apple's
        // docs describe currentContextDrawing's coordinate system only as "the
        // coordinate system of UIKit or AppKit, depending on the platform" —
        // ambiguous for macOS (AppKit's un-flipped default is bottom-left/Y-up,
        // same as CoreGraphics, but the phrase is explicitly contrasted with the
        // "Core Graphics's coordinate system" of *this* initializer, implying it
        // may be flipped instead). `drawing:` is documented unambiguously as
        // "Core Graphics's coordinate system" (origin bottom-left, Y up), so
        // this sidesteps the ambiguity entirely rather than guessing.
        handler(QLThumbnailReply(contextSize: size) { context in
            Self.draw(lines: lines, in: size, context: context)
            return true
        }, nil)
    }

    /// First 18 lines, tabs expanded, hard-truncated to 80 chars, leading
    /// blank lines skipped. Internal (not private) for unit testing.
    static func snippetLines(from source: String) -> [String] {
        source
            .replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: .newlines)
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(18)
            .map { String($0.prefix(80)) }
    }

    // MARK: - Drawing
    //
    // `context` is in Core Graphics's coordinate system: origin bottom-left,
    // Y increases upward. We bridge AppKit's higher-level string/path drawing
    // (NSString.draw, NSBezierPath) onto it via NSGraphicsContext(cgContext:
    // flipped: false) so AppKit calls land in that same un-flipped space —
    // no hidden re-flip, no ambiguity about which convention is active.
    private static func draw(lines: [String], in size: CGSize, context: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        let rect = CGRect(origin: .zero, size: size)
        NSColor.white.setFill()
        rect.fill()

        let fontSize = max(4, size.height / 26)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
        ]
        let inset = fontSize
        var y = size.height - inset - fontSize   // bottom-left origin, Y up: start near the top
        for line in lines {
            (line as NSString).draw(at: CGPoint(x: inset, y: y), withAttributes: attrs)
            y -= fontSize * 1.35
            if y < inset + fontSize * 2 { break }
        }

        // Purple "blade" badge, bottom-right.
        let badgeText = "blade" as NSString
        let badgeFont = NSFont.boldSystemFont(ofSize: fontSize * 1.2)
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont, .foregroundColor: NSColor.white,
        ]
        let textSize = badgeText.size(withAttributes: badgeAttrs)
        let pad = fontSize * 0.6
        let badgeRect = CGRect(
            x: size.width - textSize.width - pad * 2 - inset,
            y: inset,
            width: textSize.width + pad * 2,
            height: textSize.height + pad)
        let path = NSBezierPath(roundedRect: badgeRect,
                                xRadius: badgeRect.height / 2, yRadius: badgeRect.height / 2)
        NSColor.purple.setFill()
        path.fill()
        badgeText.draw(
            at: CGPoint(x: badgeRect.minX + pad, y: badgeRect.minY + pad / 2),
            withAttributes: badgeAttrs)
    }
}
