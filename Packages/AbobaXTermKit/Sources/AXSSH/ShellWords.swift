import AXL10n
import Foundation

/// POSIX-shell-like word splitting (quotes and backslashes, no expansion).
public enum ShellWords {
    public enum ParseError: Error, Equatable, LocalizedError {
        case unterminatedQuote(Character)
        case trailingBackslash

        public var errorDescription: String? {
            switch self {
            case .unterminatedQuote(let q): L("Unterminated %@ quote", q)
            case .trailingBackslash: L("Trailing backslash")
            }
        }
    }

    public static func split(_ input: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = input.makeIterator()

        while let ch = iterator.next() {
            switch ch {
            case "'":
                inWord = true
                var closed = false
                while let c = iterator.next() {
                    if c == "'" { closed = true; break }
                    current.append(c)
                }
                if !closed { throw ParseError.unterminatedQuote("'") }
            case "\"":
                inWord = true
                var closed = false
                while let c = iterator.next() {
                    if c == "\"" { closed = true; break }
                    if c == "\\" {
                        guard let next = iterator.next() else { throw ParseError.unterminatedQuote("\"") }
                        if ["\"", "\\", "$", "`"].contains(next) {
                            current.append(next)
                        } else {
                            current.append(c)
                            current.append(next)
                        }
                        continue
                    }
                    current.append(c)
                }
                if !closed { throw ParseError.unterminatedQuote("\"") }
            case "\\":
                guard let next = iterator.next() else { throw ParseError.trailingBackslash }
                inWord = true
                current.append(next)
            case _ where ch.isWhitespace:
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                inWord = true
                current.append(ch)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Quotes a word for display in a copy-pasteable command line.
    public static func quote(_ word: String) -> String {
        if word.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-")
        if word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
