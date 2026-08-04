import Foundation

struct DefaultStylesheet {

    /// Approximates Flux UI's default appearance for the static preview. BladeTranspiler rewrites
    /// `<flux:*>` tags to native elements carrying these `data-flux-*` hooks (it can't run Flux's
    /// runtime class computation), so this shim supplies the component "chrome" — borders, padding,
    /// radii, type scale — while the app's own inlined utility classes handle colors/spacing.
    /// Includes light-mode geometry + colors and dark-mode color overrides.
    static let fluxShimCSS = """
    [data-flux-card]{background:#fff;border:1px solid #e4e4e7;border-radius:.75rem;padding:1.5rem}
    [data-flux-heading]{font-weight:600;color:#27272a;font-size:.875rem;line-height:1.4;margin:0}
    [data-flux-heading][data-flux-size="lg"]{font-size:1rem}
    [data-flux-heading][data-flux-size="xl"]{font-size:1.5rem;line-height:1.2}
    [data-flux-subheading]{color:#71717a;font-size:.875rem;margin:0}
    [data-flux-text]{color:#52525b;font-size:.875rem;margin:.25rem 0}
    [data-flux-callout]{display:flex;gap:.625rem;border:1px solid #e4e4e7;border-radius:.75rem;padding:1rem;background:#fafafa}
    [data-flux-callout-heading]{font-weight:600;color:#27272a;font-size:.875rem;margin:0}
    [data-flux-field]{display:block;margin-bottom:1rem}
    [data-flux-label]{display:block;font-weight:500;font-size:.875rem;color:#3f3f46;margin-bottom:.375rem}
    [data-flux-description]{color:#71717a;font-size:.8125rem;margin:.25rem 0}
    [data-flux-error]{color:#e7000b;font-size:.8125rem;margin-top:.375rem}
    [data-flux-badge]{display:inline-flex;align-items:center;gap:.25rem;font-weight:500;font-size:.875rem;line-height:1.25;padding:.125rem .5rem;border-radius:.375rem;background:#f4f4f5;color:#3f3f46;border:1px solid #e4e4e7}
    [data-flux-button]{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;font-weight:500;font-size:.875rem;line-height:1.25;padding:.375rem .85rem;border-radius:.5rem;border:1px solid #d4d4d8;background:#fff;color:#3f3f46;cursor:pointer;text-decoration:none;white-space:nowrap}
    [data-flux-button][data-flux-variant="primary"]{background:#27272a;color:#fff;border-color:#27272a}
    [data-flux-button][data-flux-variant="danger"]{background:#e7000b;color:#fff;border-color:#e7000b}
    [data-flux-button][data-flux-variant="filled"]{background:#f4f4f5;border-color:transparent}
    [data-flux-button][data-flux-variant="ghost"],[data-flux-button][data-flux-variant="subtle"]{background:transparent;border-color:transparent}
    [data-flux-link]{color:#2563eb;font-weight:500;text-decoration:underline;text-underline-offset:2px;cursor:pointer}
    [data-flux-input]{display:block;width:100%;box-sizing:border-box;font-size:.875rem;padding:.4rem .625rem;border:1px solid #d4d4d8;border-radius:.5rem;background:#fff;color:#27272a}
    textarea[data-flux-input]{min-height:5rem}
    [data-flux-separator]{border:none;border-top:1px solid #e4e4e7;margin:1rem 0;height:0}
    [data-flux-avatar]{display:inline-flex;align-items:center;justify-content:center;width:2.25rem;height:2.25rem;border-radius:9999px;background:#e4e4e7;color:#52525b;font-size:.75rem;font-weight:600;overflow:hidden;flex-shrink:0}
    [data-flux-switch]{position:relative;display:inline-block;width:2rem;height:1.15rem;border-radius:9999px;background:#d4d4d8;flex-shrink:0;vertical-align:middle}
    [data-flux-switch]::after{content:"";position:absolute;top:2px;left:2px;width:calc(1.15rem - 4px);height:calc(1.15rem - 4px);border-radius:9999px;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.2)}
    [data-flux-checkbox],[data-flux-radio]{width:1rem;height:1rem;flex-shrink:0;margin-top:.15rem;accent-color:#27272a}
    [data-flux-control-row]{display:flex;align-items:flex-start;justify-content:space-between;gap:1rem;padding:.5rem 0}
    [data-flux-control-row] [data-flux-label]{margin-bottom:.15rem}
    [data-flux-control-row] [data-flux-description]{margin:0}
    [data-flux-menu]{display:flex;flex-direction:column;gap:.125rem}
    [data-flux-menu-item]{padding:.375rem .625rem;border-radius:.375rem;font-size:.875rem;color:#3f3f46}
    [data-flux-tabs]{display:flex;gap:.25rem;background:#f4f4f5;border-radius:.625rem;padding:.25rem}
    [data-flux-tab]{flex:1;border:0;background:transparent;padding:.4rem .75rem;border-radius:.45rem;font-size:.875rem;font-weight:500;color:#52525b;cursor:pointer;white-space:nowrap;text-align:center}
    [data-flux-tabs] [data-flux-tab]:first-child{background:#fff;color:#18181b;box-shadow:0 1px 2px rgba(0,0,0,.06)}
    [data-flux-modal]{display:none}
    table[data-flux-table]{width:100%;border-collapse:collapse;font-size:.875rem}
    [data-flux-table] th{text-align:left;font-weight:600;color:#52525b;padding:.5rem .75rem;border-bottom:1px solid #e4e4e7}
    [data-flux-table] td{padding:.5rem .75rem;border-bottom:1px solid #f4f4f5}
    \(appShellCSS)
    \(fluxShimDarkCSS)
    """

    /// App-shell geometry for full-page Livewire views composed into a Flux layout
    /// (`<flux:sidebar>`/`<flux:header>`/`<flux:main>`). Flux's own runtime CSS — which positions
    /// the fixed sidebar and offsets the content — isn't present in a static preview, so this
    /// supplies it. Every rule is gated on an actual `[data-flux-sidebar]` being on the page
    /// (`:has()`), so pages without a Flux sidebar (content-only bare pages) are
    /// completely unaffected. Dynamic bits ($auth avatar, active nav states) render empty/inert.
    static let appShellCSS = """
    body:has([data-flux-sidebar]){display:block;padding-left:16rem;box-sizing:border-box}
    [data-flux-sidebar]{position:fixed;top:0;left:0;bottom:0;width:16rem;box-sizing:border-box;overflow-y:auto;display:flex;flex-direction:column;gap:.125rem;padding:1rem .75rem;background:#fafafa;border-right:1px solid #e4e4e7;z-index:30}
    [data-flux-sidebar-header]{display:flex;align-items:center;gap:.5rem;padding:.25rem .25rem .75rem}
    [data-flux-sidebar-brand]{display:flex;align-items:center;gap:.5rem;font-weight:600;color:#27272a;text-decoration:none;font-size:.95rem;min-width:0}
    [data-flux-sidebar-brand] img{width:2rem;height:2rem;border-radius:9999px;flex-shrink:0;background:#e4e4e7}
    [data-flux-sidebar-nav]{display:flex;flex-direction:column;gap:.0625rem}
    [data-flux-sidebar-item]{display:flex;align-items:center;gap:.75rem;padding:.5rem .625rem;border-radius:.5rem;color:#3f3f46;text-decoration:none;font-size:.875rem;font-weight:500;line-height:1.25;white-space:nowrap}
    [data-flux-sidebar-item] i,[data-flux-sidebar-item] svg{width:1.25rem;text-align:center;color:#71717a;flex-shrink:0}
    [data-flux-sidebar-item]:hover{background:#f4f4f5;color:#18181b}
    [data-flux-sidebar-item] strong{font-size:.7rem;text-transform:uppercase;letter-spacing:.05em;color:#a1a1aa;font-weight:600}
    [data-flux-header]{display:flex;align-items:center;gap:.75rem;min-height:3.5rem;padding:.5rem 1rem;position:sticky;top:0;z-index:20}
    [data-flux-header] [data-flux-navbar]{display:flex;align-items:center;gap:.25rem}
    [data-flux-header] form{margin:0;display:flex}
    [data-flux-header] [data-flux-generic]{display:flex;align-items:center;gap:.25rem}
    [data-flux-header] [data-flux-input]{width:auto;min-width:13rem}
    [data-flux-navbar-item]{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;padding:.4rem .6rem;border-radius:.5rem;color:#3f3f46;text-decoration:none;font-size:.875rem;font-weight:500}
    [data-flux-navbar-item] i,[data-flux-navbar-item] svg{color:#52525b}
    [data-flux-spacer]{flex:1}
    /* Flux's real flux:main computes horizontal padding at PHP runtime (vendor main.blade.php);
       our static transpiler only sees the author's literal class attribute, so that default
       padding is invisible to us and content renders flush against the sidebar edge. 2rem
       matches Flux's lg: value — the preview always renders at desktop width (1200pt). :where()
       keeps this at zero specificity so any real padding class the author did write wins. */
    :where([data-flux-main]){padding-left:2rem;padding-right:2rem}
    """

    /// Color-only dark-mode overrides for the Flux shim (Flux's zinc dark
    /// palette). Geometry (padding, radii, layout) is NOT duplicated — these
    /// rules override colors only, so they stay in lockstep with the light
    /// rules above by construction.
    static let fluxShimDarkCSS = """
    @media (prefers-color-scheme: dark) {
    [data-flux-card]{background:#18181b;border-color:#3f3f46}
    [data-flux-heading]{color:#fafafa}
    [data-flux-subheading]{color:#a1a1aa}
    [data-flux-text]{color:#a1a1aa}
    [data-flux-callout]{background:#27272a;border-color:#3f3f46}
    [data-flux-callout-heading]{color:#fafafa}
    [data-flux-label]{color:#d4d4d8}
    [data-flux-description]{color:#a1a1aa}
    [data-flux-error]{color:#ff6467}
    [data-flux-badge]{background:#27272a;color:#d4d4d8;border-color:#3f3f46}
    [data-flux-button]{background:#27272a;color:#e4e4e7;border-color:#52525b}
    [data-flux-button][data-flux-variant="primary"]{background:#fafafa;color:#18181b;border-color:#fafafa}
    [data-flux-button][data-flux-variant="danger"]{background:#e7000b;color:#fff;border-color:#e7000b}
    [data-flux-button][data-flux-variant="filled"]{background:#3f3f46;border-color:transparent}
    [data-flux-link]{color:#60a5fa}
    [data-flux-input]{background:#27272a;border-color:#52525b;color:#fafafa}
    [data-flux-separator]{border-top-color:#3f3f46}
    [data-flux-avatar]{background:#3f3f46;color:#d4d4d8}
    [data-flux-switch]{background:#52525b}
    [data-flux-menu-item]{color:#d4d4d8}
    [data-flux-menu-item]:hover{background:#27272a}
    [data-flux-tabs]{background:#27272a}
    [data-flux-tab]{color:#a1a1aa}
    [data-flux-tabs] [data-flux-tab]:first-child{background:#3f3f46;color:#fafafa;box-shadow:none}
    [data-flux-table] th{color:#a1a1aa;border-bottom-color:#3f3f46}
    [data-flux-table] td{border-bottom-color:#27272a}
    body:has([data-flux-sidebar]){background:#0a0a0a;color:#e4e4e7}
    [data-flux-sidebar]{background:#18181b;border-right-color:#27272a}
    [data-flux-sidebar-brand]{color:#fafafa}
    [data-flux-sidebar-brand] img{background:#3f3f46}
    [data-flux-sidebar-item]{color:#d4d4d8}
    [data-flux-sidebar-item]:hover{background:#27272a;color:#fafafa}
    [data-flux-sidebar-item] strong{color:#71717a}
    [data-flux-navbar-item]{color:#d4d4d8}
    [data-flux-navbar-item] i,[data-flux-navbar-item] svg{color:#a1a1aa}
    }
    """

    /// Wraps transpiled content in a standalone HTML document. Colors are driven by CSS
    /// custom properties with light defaults plus a `prefers-color-scheme: dark` override,
    /// so the preview follows the system appearance (a QL extension can't read it at runtime).
    static func wrap(content: String, filename: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            --bg: #FFFFFF;
            --fg: #1C1C1E;
            --fg-secondary: #636366;
            --border: #D1D1D6;
            --code-bg: #F2F2F7;
            --link: #2563EB;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #1C1C1E;
                --fg: #E5E5EA;
                --fg-secondary: #8E8E93;
                --border: #38383A;
                --code-bg: #2C2C2E;
                --link: #64B5F6;
            }
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            font-size: 14px;
            line-height: 1.6;
            color: var(--fg);
            background-color: var(--bg);
            padding: 24px 32px;
            margin: 0;
        }
        h1 { font-size: 28px; font-weight: bold; margin: 16px 0 12px 0; }
        h2 { font-size: 22px; font-weight: bold; margin: 14px 0 10px 0; }
        h3 { font-size: 18px; font-weight: 600; margin: 12px 0 8px 0; }
        h4 { font-size: 16px; font-weight: 600; margin: 10px 0 6px 0; }
        p { margin: 8px 0; }
        a { color: var(--link); text-decoration: underline; }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 12px 0;
        }
        th, td {
            border: 1px solid var(--border);
            padding: 8px 12px;
            text-align: left;
        }
        th {
            background-color: var(--code-bg);
            font-weight: 600;
        }
        code {
            font-family: "SF Mono", Menlo, monospace;
            font-size: 12px;
            background-color: var(--code-bg);
            padding: 1px 4px;
            border-radius: 3px;
        }
        label {
            font-weight: 600;
            display: block;
            margin-top: 12px;
            margin-bottom: 4px;
        }
        input[type="text"], input[type="email"], textarea {
            display: block;
            width: 90%;
            padding: 8px;
            margin: 4px 0;
            border: 1px solid var(--border);
            border-radius: 4px;
            font-size: 14px;
            background-color: var(--code-bg);
            color: var(--fg);
        }
        .btn {
            display: inline-block;
            padding: 8px 16px;
            border-radius: 4px;
            font-size: 14px;
            font-weight: 600;
            text-decoration: none;
            margin: 4px 4px 4px 0;
        }
        .btn-primary {
            background-color: #2563EB;
            color: #FFFFFF;
        }
        .btn-secondary {
            background-color: var(--code-bg);
            color: var(--fg-secondary);
            border: 1px solid var(--border);
        }
        .filename-header {
            font-family: "SF Mono", Menlo, monospace;
            font-size: 11px;
            color: var(--fg-secondary);
            border-bottom: 1px solid var(--border);
            padding-bottom: 8px;
            margin-bottom: 16px;
        }
        \(fluxShimCSS)
        </style>
        </head>
        <body>
        <div class="filename-header">\(escapeHTML(filename))</div>
        \(content)
        </body>
        </html>
        """
    }

    /// Escapes the five characters that change meaning in HTML text or in an attribute
    /// value under either quote style. `'` matters because component templates
    /// legitimately write `title='{{ $x }}'`, and a prop containing an apostrophe used
    /// to close that attribute early and turn the rest of the value into markup.
    /// `&#39;` rather than `&apos;` — the named form isn't defined in HTML 4.
    static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
