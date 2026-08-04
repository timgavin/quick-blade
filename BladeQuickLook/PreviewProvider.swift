import Cocoa
import QuickLookUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.quickblade.BladeQuickLook", category: "preview")

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(
        for request: QLFilePreviewRequest,
        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void
    ) {
        let fileURL = request.fileURL
        logger.info("providePreview called for: \(fileURL.lastPathComponent)")

        // We claim all of public.php-script, so non-Blade PHP lands here too.
        // QL does not fall back to its built-in preview when we error (verified),
        // so render plain PHP as escaped source rather than degrade it.
        guard fileURL.lastPathComponent.lowercased().hasSuffix(".blade.php") else {
            do {
                let source = try Self.readSource(from: fileURL)
                let html = DefaultStylesheet.wrap(
                    content: "<pre><code>\(Self.escapePre(source))</code></pre>",
                    filename: fileURL.lastPathComponent
                )
                guard let data = html.data(using: .utf8) else {
                    handler(nil, PreviewError.encodingFailed)
                    return
                }
                // Same size as the Blade path below, so plain-PHP and Blade
                // previews open consistently. (The breakpoint rationale lives there.)
                let reply = QLPreviewReply(
                    dataOfContentType: .html,
                    contentSize: CGSize(width: 1200, height: 800)
                ) { _ in data }
                handler(reply, nil)
            } catch {
                handler(nil, error)
            }
            return
        }

        do {
            let source = try Self.readSource(from: fileURL)
            let filename = fileURL.lastPathComponent
            var html: String

            // Try template resolution (layout + CSS inlining)
            let resolved = TemplateResolver.resolve(source: source, fileURL: fileURL)

            if resolved.didResolveLayout {
                logger.info("Template resolved (CSS inlined: \(resolved.didInlineCSS))")
                html = BladeTranspiler.transpile(resolved.html)
            } else {
                logger.info("No layout found, using single-file fallback")
                let transpiled = BladeTranspiler.transpile(source)
                html = DefaultStylesheet.wrap(
                    content: transpiled,
                    filename: filename
                )
            }

            if let message = DiagnosticsStrip.message(for: resolved.diagnostics) {
                logger.info("Appending diagnostics strip")
                html = DiagnosticsStrip.inject(into: html, message: message)
            }

            guard let data = html.data(using: .utf8) else {
                handler(nil, PreviewError.encodingFailed)
                return
            }

            // Desktop-first previews: below lg (1024px) real apps render mobile
            // chrome (fixed bottom navs) that overlays content in a static preview.
            let reply = QLPreviewReply(
                dataOfContentType: .html,
                contentSize: CGSize(width: 1200, height: 800)
            ) { _ in
                return data
            }

            handler(reply, nil)
        } catch {
            logger.error("Failed to render preview: \(error.localizedDescription)")
            handler(nil, error)
        }
    }

    /// Reads the file as text: UTF-8 first, then a sniffed encoding, then Latin-1
    /// (which maps every byte) so a non-UTF-8 template renders instead of hard-failing.
    private static func readSource(from fileURL: URL) throws -> String {
        if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) {
            return utf8
        }
        var used: String.Encoding = .utf8
        if let sniffed = try? String(contentsOf: fileURL, usedEncoding: &used) {
            return sniffed
        }
        return try String(contentsOf: fileURL, encoding: .isoLatin1)
    }

    private static func escapePre(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum PreviewError: Error, LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode HTML as UTF-8."
        }
    }
}
