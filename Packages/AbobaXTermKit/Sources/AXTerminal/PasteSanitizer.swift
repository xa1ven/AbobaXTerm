import Foundation

/// Pasted text with the typography of chat apps turned back into what was typed.
public struct SanitizedPaste: Equatable, Sendable {
    public var text: String
    /// UTF-16 ranges of `text` that stand in for typographic characters.
    public var fixedRanges: [NSRange] = []
    /// UTF-16 ranges of dashes left alone: "--", "---" or a real dash, nobody can tell.
    public var unresolvedRanges: [NSRange] = []
    /// Invisible characters (zero width space, BOM) that were dropped.
    public var removedCount = 0

    public var isChanged: Bool { !fixedRanges.isEmpty || removedCount > 0 }
}

/// Undoes what messengers and "smart" text fields do to commands: curly and
/// angle quotes, dashes made of two hyphens, the ellipsis character,
/// non-breaking and invisible spaces.
public enum PasteSanitizer {
    private static let doubleQuotes: Set<Unicode.Scalar> = ["«", "»", "„", "“", "”", "‟", "″"]
    private static let singleQuotes: Set<Unicode.Scalar> = ["‘", "’", "‚", "‛", "′"]
    private static let dashes: Set<Unicode.Scalar> = ["—", "–", "―"]
    /// NBSP, figure/thin/narrow and the other fixed-width spaces.
    private static let spaces: Set<Unicode.Scalar> = [
        "\u{00A0}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}",
        "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}",
    ]
    /// Zero width space, word joiner, BOM. ZWJ/ZWNJ stay: emoji and some scripts need them.
    private static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{2060}", "\u{FEFF}"]

    public static func sanitize(_ text: String) -> SanitizedPaste {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var length = 0 // UTF-16 length of `out`
        var result = SanitizedPaste(text: "")

        func keep(_ scalar: Unicode.Scalar) {
            out.append(scalar)
            length += scalar.utf16.count
        }
        func replace(with ascii: String) {
            result.fixedRanges.append(NSRange(location: length, length: ascii.utf16.count))
            out.append(contentsOf: ascii.unicodeScalars)
            length += ascii.utf16.count
        }

        var index = 0
        while index < scalars.count {
            // One line: [index, lineEnd), then its terminator.
            var lineEnd = index
            while lineEnd < scalars.count, scalars[lineEnd] != "\n", scalars[lineEnd] != "\r" { lineEnd += 1 }

            if let rule = dashRule(scalars[index..<lineEnd]) {
                // A line of nothing but dashes: a YAML document separator or a ruler.
                for scalar in scalars[index..<rule.start] { keep(scalar) }
                replace(with: String(repeating: "-", count: rule.hyphens))
                for scalar in scalars[rule.end..<lineEnd] { keep(scalar) }
            } else {
                for position in index..<lineEnd {
                    let scalar = scalars[position]
                    if doubleQuotes.contains(scalar) {
                        replace(with: "\"")
                    } else if singleQuotes.contains(scalar) {
                        replace(with: "'")
                    } else if scalar == "…" {
                        replace(with: "...")
                    } else if spaces.contains(scalar) {
                        replace(with: " ")
                    } else if invisible.contains(scalar) {
                        result.removedCount += 1
                    } else if dashes.contains(scalar) {
                        let before = position > index ? scalars[position - 1] : nil
                        let after = position + 1 < lineEnd ? scalars[position + 1] : nil
                        if isOptionStart(before: before, after: after) {
                            replace(with: "--")
                        } else {
                            result.unresolvedRanges.append(NSRange(location: length, length: scalar.utf16.count))
                            keep(scalar)
                        }
                    } else {
                        keep(scalar)
                    }
                }
            }

            index = lineEnd
            while index < scalars.count, scalars[index] == "\n" || scalars[index] == "\r" {
                keep(scalars[index])
                index += 1
                if scalars[index - 1] == "\n" { break }
            }
        }

        result.text = String(out)
        return result
    }

    /// A dash that starts a word, as in "ls —all": it was "--" before the long option.
    private static func isOptionStart(before: Unicode.Scalar?, after: Unicode.Scalar?) -> Bool {
        guard let after, after.isASCII, CharacterSet.alphanumerics.contains(after) else { return false }
        guard let before else { return true }
        return before == " " || before == "\t" || spaces.contains(before)
    }

    /// For a line made only of dashes and hyphens with at least one typographic
    /// dash: where the run sits and how many hyphens it stands for (never fewer
    /// than three, "---" is what such a line was almost certainly).
    private static func dashRule(_ line: ArraySlice<Unicode.Scalar>) -> (start: Int, end: Int, hyphens: Int)? {
        var start = line.startIndex
        var end = line.endIndex
        while start < end, line[start] == " " || line[start] == "\t" { start += 1 }
        while end > start, line[end - 1] == " " || line[end - 1] == "\t" { end -= 1 }
        guard start < end else { return nil }
        var hyphens = 0
        var typographic = false
        for scalar in line[start..<end] {
            if scalar == "-" {
                hyphens += 1
            } else if dashes.contains(scalar) {
                hyphens += 2
                typographic = true
            } else {
                return nil
            }
        }
        return typographic ? (start, end, max(hyphens, 3)) : nil
    }
}
