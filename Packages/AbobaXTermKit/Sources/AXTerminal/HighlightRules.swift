import Foundation

/// Regex rules used by `OutputHighlighter`. Colors are ANSI palette indexes,
/// so they follow the terminal theme (light/dark).
enum HighlightRules {
    enum Style {
        case color(Int)   // SGR foreground code, e.g. 91 = bright red
        case underline

        var open: String {
            switch self {
            case .color(let code): "\u{1B}[\(code)m"
            case .underline: "\u{1B}[4m"
            }
        }

        var close: String {
            switch self {
            case .color: "\u{1B}[39m"
            case .underline: "\u{1B}[24m"
            }
        }
    }

    struct Rule {
        let regex: NSRegularExpression
        let style: Style
        /// Capture group to color (0 = whole match).
        let group: Int
        let skip: (@Sendable (String) -> Bool)?

        init(_ pattern: String, _ style: Style, group: Int = 0, caseInsensitive: Bool = false,
             skip: (@Sendable (String) -> Bool)? = nil) {
            // Patterns are constants; a typo should fail loudly in debug builds.
            regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            self.style = style
            self.group = group
            self.skip = skip
        }
    }

    static let red = 91, green = 92, yellow = 93, blue = 94, magenta = 95, cyan = 96
    static let flagColor = 36 // cyan, a bit calmer than IPv6's bright cyan

    private static let octet = "(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)"

    /// Earlier rules win when matches overlap.
    static let rules: [Rule] = [
        // URLs
        Rule(#"\b(?:https?|ftp|ssh|sftp)://[^\s<>"'`]+[^\s<>"'`.,;:!?)\]]"#, .underline),
        // IPv4 (0.0.0.0 is just "any", left plain)
        Rule("(?<![\\d.])\(octet)(?:\\.\(octet)){3}(?!\\d|\\.\\d)", .color(magenta), skip: { $0 == "0.0.0.0" }),
        // IPv6 in brackets, e.g. [::1]:22 or [fe80::1]
        Rule(#"\[[0-9A-Fa-f:.%a-z]*:[0-9A-Fa-f:.%a-z]*\]"#, .color(cyan)),
        // Bare IPv6 with "::" (avoids matching times like 12:34:56)
        Rule(#"(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){1,7}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?(?![\w:])"#, .color(cyan)),
        // MAC addresses
        Rule(#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, .color(magenta)),
        // Phrases (before single words so the whole phrase gets one color)
        Rule(#"\bactive \((?:running|exited|listening|waiting)\)"#, .color(green)),
        Rule(#"\bconnection (?:closed|reset)\b"#, .color(yellow), caseInsensitive: true),
        Rule(#"\b(?:connection (?:refused|timed out)|broken pipe|permission denied|no such file or directory|not found|timed out|access denied|authentication failure)\b"#, .color(red), caseInsensitive: true),
        Rule(#"\b(?:session (?:opened|closed))\b"#, .color(green), caseInsensitive: true),
        Rule(#"\blast login\b:?"#, .color(blue), caseInsensitive: true),
        // Errors
        Rule(#"\b(?:errors?|failed|failure|fatal|invalid|denied|refused|critical|panic|unreachable|unable|cannot|can't|corrupt(?:ed)?|segfault|killed|aborted?|exception|illegal|forbidden|unauthorized|disconnected)\b"#, .color(red), caseInsensitive: true),
        // Warnings / neutral-negative states
        Rule(#"\b(?:warn(?:ing)?s?|disabled|inactive|closed|reset|deprecated|expired|degraded|dead|stopped|timeout|retry(?:ing)?|skipp(?:ed|ing)|pending|unknown|masked)\b"#, .color(yellow), caseInsensitive: true),
        // Success / positive states (not field labels such as "Active:")
        Rule(#"\b(?:success(?:ful(?:ly)?)?|succeeded|accepted|enabled|active|running|started|opened|online|connected|established|passed|completed?|done|ready|healthy|ok)\b(?!:)"#, .color(green), caseInsensitive: true),
        // Process ids like sshd[1234]
        Rule(#"\[(\d+)\]"#, .color(blue), group: 1),
        // Command-line flags: -a, -la, --upgradable, --format=json.
        // A lone "-"/"--" only at the very end, i.e. while it is being typed.
        Rule(#"(?<=\s|^)--?(?:[A-Za-z0-9][\w.=,:/@+-]*|$)"#, .color(flagColor)),
    ]

    /// Returns `text` with SGR sequences inserted around matches.
    ///
    /// `context` is text already printed before `text` on the same line; it
    /// takes part in matching but is not part of the result.
    static func apply(to text: String, context: String = "") -> String {
        // Fast path: text that cannot match anything.
        guard text.contains(where: { $0.isLetter || $0.isNumber || $0 == "[" || $0 == "-" }) else { return text }

        let combined = context + text
        let ns = combined as NSString
        let full = NSRange(location: 0, length: ns.length)
        let start = (context as NSString).length
        var spans: [(range: NSRange, style: Style)] = []

        for rule in rules {
            for match in rule.regex.matches(in: combined, range: full) {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                if let skip = rule.skip, skip(ns.substring(with: range)) { continue }
                if spans.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { continue }
                spans.append((range, rule.style))
            }
        }
        // Keep only the parts that fall into `text`.
        spans = spans.compactMap { span in
            let clipped = NSIntersectionRange(span.range, NSRange(location: start, length: ns.length - start))
            return clipped.length > 0 ? (clipped, span.style) : nil
        }
        guard !spans.isEmpty else { return text }

        spans.sort { $0.range.location < $1.range.location }
        var result = ""
        result.reserveCapacity(text.utf8.count + spans.count * 10)
        var cursor = start
        for span in spans {
            result += ns.substring(with: NSRange(location: cursor, length: span.range.location - cursor))
            result += span.style.open
            result += ns.substring(with: span.range)
            result += span.style.close
            cursor = NSMaxRange(span.range)
        }
        result += ns.substring(from: cursor)
        return result
    }
}
