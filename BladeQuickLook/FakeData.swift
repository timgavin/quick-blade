import Foundation

/// Deterministic stand-in values for Blade echo expressions the preview cannot
/// evaluate. Every value is a fixed constant — no randomness, no current date —
/// so transpiled output is stable and unit-testable.
///
/// Iteration is carried inside the expression itself: BladeTranspiler's loop
/// expansion prefixes echo expressions in repeated loop bodies with
/// "QBITER<n> " (n = 0-based iteration). No marker means iteration 0. When
/// markers nest (loop in loop), the FIRST marker wins — the outermost loop
/// injects last and prepends, so rows of a table vary by outer iteration.
struct FakeData {

    // MARK: - Public API

    static func value(for rawExpression: String) -> String {
        let (expression, iteration) = stripIterationMarkers(from: rawExpression)
        let p = personas[iteration % personas.count]

        let segments = identifierSegments(of: expression)
        guard let lastSegment = segments.last else {
            return suffixed("Sample", iteration)
        }
        let words = splitWords(lastSegment)

        // Multi-word rules beat single-word rules (spec: first_name → Jane).
        if words.contains("first") && words.contains("name") { return p.first }
        if (words.contains("last") && words.contains("name")) || words.contains("surname") {
            return p.last
        }

        // Context rule: the last segment is a generic label word (name/title/
        // label) — classify by the EARLIER segments' words, in precedence
        // order: person > place > org > item (anything else non-empty).
        // A bare label with no earlier segment (e.g. `$name`) falls through
        // to the single-word rules below. Fixes `$item['name']` rendering
        // "Jane Doe" instead of an item, while `$user['name']` stays a person
        // and `$location->location->name` stays a city.
        if words.allSatisfy({ genericLabelWords.contains($0) }) {
            let earlierWords = segments.dropLast().flatMap(splitWords)
            if !earlierWords.isEmpty {
                if earlierWords.contains(where: { personWords.contains($0) }) {
                    return p.full
                }
                if earlierWords.contains(where: { placeWords.contains($0) }) {
                    return p.city
                }
                if earlierWords.contains(where: { orgWords.contains($0) }) {
                    return p.company
                }
                return suffixed("Sample Item", iteration)
            }
        }

        // Single-word rules, rightmost word first (spec: user_id → 42, not Jane Doe).
        for word in words.reversed() {
            if let v = singleWordValue(word, persona: p, iteration: iteration) { return v }
        }
        return suffixed("Sample", iteration)
    }

    /// Words that, alone, don't say WHAT is being labeled — context (an
    /// earlier segment in the chain) decides whether the value is a person's
    /// name or something else (e.g. a place).
    private static let genericLabelWords: Set<String> = ["name", "title", "label"]

    /// Words that mark a segment as referring to a place.
    private static let placeWords: Set<String> = [
        "location", "place", "city", "region", "area", "venue", "destination",
    ]

    /// Words that mark a segment as referring to a person — a "name"-like
    /// field under one of these is a person's name, not an item or place.
    /// `address` is included: an address object's `name` is its recipient.
    private static let personWords: Set<String> = [
        "user", "author", "member", "customer", "owner", "profile", "account",
        "admin", "sender", "recipient", "employee", "friend", "follower", "address",
        "creator", "assignee", "manager", "editor", "reviewer", "buyer", "seller",
        "client", "staff", "contact", "person", "guest", "host", "moderator",
    ]

    /// Words that mark a segment as referring to an organization.
    private static let orgWords: Set<String> = [
        "company", "team", "organization", "organisation", "brand", "vendor",
        "store", "shop", "agency",
    ]

    // MARK: - Personas

    private struct Persona {
        let first: String, last: String, email: String, phone: String
        let date: String, time: String, money: String, number: String, percent: String
        let city: String, street: String, status: String, company: String
        var full: String { "\(first) \(last)" }
    }

    // money is a BARE number ("24.00", not "$24.00") — templates like
    // `${{ number_format(...) }}` or `{{ ... }}%` supply their own currency
    // symbol / percent sign; a doubled-up "$$24.00" is the bug this avoids.
    private static let personas: [Persona] = [
        Persona(first: "Jane", last: "Doe", email: "jane@example.com", phone: "(555) 010-4477",
                date: "Jun 12, 2026", time: "9:41 AM", money: "24.00", number: "42", percent: "12",
                city: "Portland", street: "123 Main Street", status: "Active", company: "Acme Corp"),
        Persona(first: "John", last: "Smith", email: "john@example.com", phone: "(555) 010-2318",
                date: "Mar 3, 2026", time: "2:17 PM", money: "9.50", number: "17", percent: "8",
                city: "Austin", street: "456 Oak Avenue", status: "Pending", company: "Globex Ltd"),
        Persona(first: "Alex", last: "Rivera", email: "alex@example.com", phone: "(555) 010-9902",
                date: "Nov 21, 2025", time: "11:05 AM", money: "132.00", number: "128", percent: "31",
                city: "Chicago", street: "789 Pine Road", status: "Active", company: "Initech Inc"),
    ]

    private static func singleWordValue(_ word: String, persona p: Persona, iteration: Int) -> String? {
        switch word {
        case "name", "username", "author", "user": return p.full
        case "email": return p.email
        case "phone", "tel": return p.phone
        case "at", "date", "birthday": return p.date
        case "time": return p.time
        case "price", "amount", "total", "cost", "balance", "revenue", "earnings": return p.money
        case "count", "qty", "quantity", "views", "likes", "downloads",
             "id", "number": return p.number
        case "growth", "rate", "percent", "percentage": return p.percent
        case "title", "subject", "heading", "label":
            return suffixed("Sample Item", iteration)
        case "description", "body", "content", "excerpt", "summary", "bio",
             "message", "text":
            // Deliberately short. The previous 54-char sentence overflowed compact
            // list rows in Quick Look's WebKit: a nested-flex truncate row that
            // Chrome shrinks correctly only partially shrinks there, pushing the
            // row past its card by up to 35px at two-column widths (measured via
            // headless WKWebView at 1024-1300px; this length fits at all widths).
            return suffixed("Stand-in preview text.", iteration)
        case "city", "location", "place", "region", "area", "venue", "destination": return p.city
        case "company", "team", "organization", "organisation", "brand", "vendor",
             "store", "shop", "agency":
            return p.company
        case "country": return "United States"
        case "address", "street": return p.street
        case "status", "state": return p.status
        case "slug", "url", "link": return "example.com/sample"
        default: return nil
        }
    }

    /// Non-persona values get a numeric suffix on repeats so rows are visibly distinct.
    private static func suffixed(_ base: String, _ iteration: Int) -> String {
        let n = iteration % personas.count
        return n == 0 ? base : "\(base) \(n + 1)"
    }

    // MARK: - Expression parsing

    /// Strips leading "QBITER<n> " markers; returns the clean expression and the
    /// iteration from the FIRST marker (0 when there is none).
    private static func stripIterationMarkers(from expression: String) -> (String, Int) {
        var rest = expression.trimmingCharacters(in: .whitespaces)
        var iteration: Int? = nil
        while let m = firstCapture(in: rest, pattern: #"^QBITER(\d+)\s+"#) {
            if iteration == nil { iteration = Int(m.capture) }
            rest = String(rest[m.matchEnd...])
        }
        return (rest, iteration ?? 0)
    }

    /// ALL value-bearing identifiers of an echo expression, in order, skipping
    /// function/method names, with string literals removed first. Array-key
    /// accesses (`['key']`) are rewritten to chain segments (`->key`) first,
    /// so keys like `revenue_growth` survive as identifiers rather than being
    /// deleted as string literals. Key-carrying helpers (old/session/config/…)
    /// use their first string argument's last dot-segment instead, returned
    /// as a single-element array.
    private static func identifierSegments(of expression: String) -> [String] {
        let expression = rewriteArrayKeysAsSegments(expression)

        if let m = firstCapture(in: expression,
            pattern: #"(?:\b(?:old|session|request|input|config|data_get)\s*\(\s*['"])([\w.\-]+)['"]"#) {
            return m.capture.split(separator: ".").last.map { [String($0)] } ?? []
        }
        let unquoted = removing(pattern: #"'[^']*'|"[^"]*""#, from: expression)
        // Possessive *+ so "format(" can't backtrack to match "forma" (same
        // idiom as balancedParens in BladeTranspiler).
        return allMatches(in: unquoted, pattern: #"[A-Za-z_][A-Za-z0-9_]*+(?!\s*\()"#)
    }

    /// Rewrites `['key']` / `["key"]` array-index access into a `->key` chain
    /// segment. Must run before quote-stripping so the key text survives as
    /// an identifier instead of being deleted as a string literal.
    private static func rewriteArrayKeysAsSegments(_ expression: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\s*['"]([\w.\-]+)['"]\s*\]"#) else {
            return expression
        }
        let range = NSRange(expression.startIndex..., in: expression)
        return regex.stringByReplacingMatches(in: expression, range: range, withTemplate: "->$1")
    }

    /// Splits an identifier on "_" and camelCase boundaries, lowercased.
    /// "createdAt" → ["created", "at"]; "first_name" → ["first", "name"].
    private static func splitWords(_ segment: String) -> [String] {
        var words: [String] = []
        for chunk in segment.split(separator: "_") {
            var current = ""
            for ch in chunk {
                if ch.isUppercase && !current.isEmpty {
                    words.append(current.lowercased())
                    current = String(ch)
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { words.append(current.lowercased()) }
        }
        return words
    }

    // MARK: - Minimal regex helpers (FakeData is self-contained)

    private static func firstCapture(
        in text: String, pattern: String
    ) -> (capture: String, matchEnd: String.Index)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let capRange = Range(m.range(at: 1), in: text),
              let fullRange = Range(m.range, in: text) else { return nil }
        return (String(text[capRange]), fullRange.upperBound)
    }

    private static func removing(pattern: String, from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
