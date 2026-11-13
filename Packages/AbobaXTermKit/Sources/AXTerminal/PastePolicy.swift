import Foundation

/// What to do with typographic characters in pasted text.
public enum TypographyFix: String, CaseIterable, Identifiable, Sendable {
    /// Show the corrected text and let the user decide.
    case ask
    /// Correct silently.
    case automatic
    case off

    public var id: String { rawValue }
}

public struct PasteSettings: Equatable, Sendable {
    /// Review text of several lines before it reaches the shell.
    public var confirmMultiline = true
    public var typography = TypographyFix.ask

    public init(confirmMultiline: Bool = true, typography: TypographyFix = .ask) {
        self.confirmMultiline = confirmMultiline
        self.typography = typography
    }
}

/// A paste held back for the user to look at and edit.
public struct PasteReview: Equatable, Sendable {
    public var original: String
    /// Corrected text; nil when there was nothing to correct.
    public var sanitized: SanitizedPaste?

    public init(original: String, sanitized: SanitizedPaste? = nil) {
        self.original = original
        self.sanitized = sanitized
    }

    public var isMultiline: Bool { PastePolicy.isMultiline(original) }
    public var lineCount: Int { PastePolicy.lineCount(sanitized?.text ?? original) }
}

public enum PasteDecision: Equatable, Sendable {
    /// Paste the clipboard the usual way.
    case passThrough
    /// Paste this text instead of the clipboard's.
    case send(String)
    case review(PasteReview)
}

public enum PastePolicy {
    /// - Parameter isAlternateScreen: a full-screen program (vim, nano, mc)
    ///   owns the terminal. Several lines pasted there are text, not commands,
    ///   so they are not held back.
    public static func decide(text: String, settings: PasteSettings, isAlternateScreen: Bool) -> PasteDecision {
        guard !text.isEmpty else { return .passThrough }
        let sanitized = settings.typography == .off ? nil : PasteSanitizer.sanitize(text)
        let fixed = sanitized?.isChanged == true ? sanitized : nil
        let confirm = settings.confirmMultiline && !isAlternateScreen && isMultiline(text)

        if let fixed, settings.typography == .ask || confirm {
            return .review(PasteReview(original: text, sanitized: fixed))
        }
        if let fixed { return .send(fixed.text) }
        return confirm ? .review(PasteReview(original: text)) : .passThrough
    }

    /// Has a line break anywhere: the shell would run at least one line at once.
    public static func isMultiline(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    /// Lines as an editor counts them; a trailing line break adds none.
    public static func lineCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return max(count, 1)
    }
}
