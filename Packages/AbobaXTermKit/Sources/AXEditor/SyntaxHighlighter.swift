import Foundation

public enum TokenKind: Sendable, CaseIterable {
    case comment, string, keyword, builtin, constant, number, variable, key, type, function, section, tag, attribute
}

public struct SyntaxToken: Equatable, Sendable {
    public var range: NSRange
    public var kind: TokenKind
}

/// Regex-based highlighter. "Regions" (comments and strings) are found in
/// one left-to-right pass so that e.g. `#` inside a string is not a comment;
/// the remaining rules only apply outside regions and never overlap.
public struct SyntaxHighlighter: Sendable {
    public let language: SyntaxLanguage
    private let grammar: Grammar

    public init(language: SyntaxLanguage) {
        self.language = language
        self.grammar = Grammar.cached(for: language)
    }

    public func tokens(in text: String) -> [SyntaxToken] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var tokens: [SyntaxToken] = []
        var covered = IndexSet()

        if let regions = grammar.regions {
            regions.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                for (index, kind) in regions.kinds.enumerated() {
                    let r = match.range(withName: "r\(index)")
                    if r.location != NSNotFound, r.length > 0 {
                        tokens.append(SyntaxToken(range: r, kind: kind))
                        covered.insert(integersIn: r.location..<r.location + r.length)
                        break
                    }
                }
            }
        }

        for rule in grammar.rules {
            rule.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                let r = match.range(at: rule.group)
                guard r.location != NSNotFound, r.length > 0 else { return }
                let span = r.location..<r.location + r.length
                guard !covered.intersects(integersIn: span) else { return }
                tokens.append(SyntaxToken(range: r, kind: rule.kind))
                covered.insert(integersIn: span)
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }
}

// MARK: - Grammars

private struct Rule: @unchecked Sendable {
    let regex: NSRegularExpression
    let kind: TokenKind
    let group: Int
}

private struct Regions: @unchecked Sendable {
    let regex: NSRegularExpression
    let kinds: [TokenKind]
}

private struct Grammar: Sendable {
    var regions: Regions?
    var rules: [Rule]

    init(regions: [(TokenKind, String)], rules: [(TokenKind, String, Int)]) {
        if regions.isEmpty {
            self.regions = nil
        } else {
            let pattern = regions.enumerated().map { "(?<r\($0.offset)>\($0.element.1))" }.joined(separator: "|")
            self.regions = Regions(regex: Self.compile(pattern), kinds: regions.map(\.0))
        }
        self.rules = rules.map { Rule(regex: Self.compile($0.1), kind: $0.0, group: $0.2) }
    }

    static func compile(_ pattern: String) -> NSRegularExpression {
        // Patterns are constants; a typo should fail loudly in tests.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [SyntaxLanguage: Grammar] = [:]

    static func cached(for language: SyntaxLanguage) -> Grammar {
        lock.withLock {
            if let g = cache[language] { return g }
            let g = make(language)
            cache[language] = g
            return g
        }
    }

    // Shared pieces.
    static let dq = #""(?:[^"\\\n]|\\.)*""#
    static let sq = #"'(?:[^'\\\n]|\\.)*'"#
    static let hashComment = #"(?:^|(?<=[\s;]))#[^\n]*"#
    static let slashComments = #"//[^\n]*|/\*[\s\S]*?\*/"#
    static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
    static let capitalizedType = #"\b[A-Z][A-Za-z0-9_]*\b"#

    static func words(_ list: String, caseInsensitive: Bool = false) -> String {
        let alternatives = list.split(separator: " ").joined(separator: "|")
        return (caseInsensitive ? "(?i)" : "") + "\\b(?:\(alternatives))\\b"
    }

    static func cStyle(keywords: String, constants: String = "true false null nil", extraRegions: [(TokenKind, String)] = [],
                       extraRules: [(TokenKind, String, Int)] = []) -> Grammar {
        Grammar(
            regions: [(.comment, slashComments)] + extraRegions + [(.string, dq), (.string, sq)],
            rules: extraRules + [
                (.keyword, words(keywords), 0),
                (.constant, words(constants), 0),
                (.number, number, 0),
                (.function, #"\b([a-z_][A-Za-z0-9_]*)\s*(?=\()"#, 1),
                (.type, capitalizedType, 0),
            ])
    }

    static func make(_ language: SyntaxLanguage) -> Grammar {
        switch language {
        case .plain:
            return Grammar(regions: [], rules: [])

        case .shell:
            return Grammar(
                regions: [(.comment, hashComment), (.string, dq), (.string, "'[^']*'")],
                rules: [
                    (.variable, #"\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9#?$!@*-])"#, 0),
                    (.keyword, words("if then else elif fi case esac for while until do done in function select time return break continue"), 0),
                    (.builtin, words("echo printf read cd pwd export unset local declare readonly source alias eval exec exit set shift test trap wait sudo"), 0),
                    (.attribute, #"(?<=\s)--?[A-Za-z][\w-]*"#, 0),
                    (.function, #"^\s*([A-Za-z_][\w-]*)\s*\(\)"#, 1),
                    (.number, #"\b\d+\b"#, 0),
                ])

        case .python:
            return Grammar(
                regions: [
                    (.string, #"[rRbBfFuU]{0,2}"""[\s\S]*?""""#),
                    (.string, #"[rRbBfFuU]{0,2}'''[\s\S]*?'''"#),
                    (.comment, #"#[^\n]*"#),
                    (.string, "[rRbBfFuU]{0,2}" + dq),
                    (.string, "[rRbBfFuU]{0,2}" + sq),
                ],
                rules: [
                    (.attribute, #"^\s*@[\w.]+"#, 0),
                    (.keyword, words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"), 0),
                    (.constant, words("True False None self cls"), 0),
                    (.builtin, words("print len range open str int float list dict set tuple bool type isinstance super enumerate zip map filter sorted min max sum abs any all"), 0),
                    (.function, #"(?<=\bdef\s)[A-Za-z_]\w*"#, 0),
                    (.type, #"(?<=\bclass\s)[A-Za-z_]\w*"#, 0),
                    (.number, number, 0),
                ])

        case .json:
            return Grammar(
                regions: [(.key, dq + #"(?=\s*:)"#), (.string, dq), (.comment, slashComments)],
                rules: [(.constant, words("true false null"), 0), (.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, 0)])

        case .yaml:
            return Grammar(
                regions: [(.comment, #"(?:^|(?<=\s))#[^\n]*"#), (.string, dq), (.string, "'(?:[^'\\n]|'')*'")],
                rules: [
                    (.section, #"^(?:---|\.\.\.)\s*$"#, 0),
                    (.key, #"^[ \t]*(?:- +)?([^\s#:'"\-][^:\n]*?|"[^"\n]*"|'[^'\n]*')(?=:(?:[ \t]|$))"#, 1),
                    (.variable, #"[&*][\w-]+"#, 0),
                    (.attribute, #"![\w!/.-]+"#, 0),
                    (.constant, words("true false yes no on off null True False Yes No On Off Null TRUE FALSE NULL"), 0),
                    (.constant, #"(?<=:\s)~$"#, 0),
                    (.number, #"(?<=[\s:\[,-])-?\d+(?:\.\d+)?(?=\s*(?:$|[,\]#]))"#, 0),
                ])

        case .toml, .ini:
            return Grammar(
                regions: [(.comment, #"^[ \t]*[#;][^\n]*"#), (.string, "\"\"\"[\\s\\S]*?\"\"\""), (.string, dq), (.string, sq)],
                rules: [
                    (.section, #"^[ \t]*\[{1,2}[^\]\n]+\]{1,2}"#, 0),
                    (.key, #"^[ \t]*([A-Za-z_][\w.\-]*)(?=[ \t]*[=:]|[ \t]+\S)"#, 1),
                    (.variable, #"\$\{?[A-Za-z_]\w*\}?|%[A-Za-z]"#, 0),
                    (.constant, words("true false yes no on off none", caseInsensitive: true), 0),
                    (.number, #"(?<![\w.])-?\d+(?:\.\d+)?[kKmMgGsShHdD]?(?![\w.])"#, 0),
                ])

        case .xml:
            return Grammar(
                regions: [(.comment, "<!--[\\s\\S]*?-->"), (.string, "<!\\[CDATA\\[[\\s\\S]*?\\]\\]>")],
                rules: [
                    (.keyword, #"<[!?][\w-]+"#, 0),
                    (.tag, #"</?\s*([\w:.-]+)"#, 1),
                    (.attribute, #"\s([\w:.-]+)(?=\s*=)"#, 1),
                    (.string, #"(?<==)\s*("[^"]*"|'[^']*')"#, 1),
                    (.constant, #"&#?\w+;"#, 0),
                ])

        case .markdown:
            return Grammar(
                regions: [(.string, "```[\\s\\S]*?```"), (.string, "`[^`\\n]+`"), (.comment, "<!--[\\s\\S]*?-->")],
                rules: [
                    (.section, #"^#{1,6}\s[^\n]*"#, 0),
                    (.comment, #"^>[^\n]*"#, 0),
                    (.attribute, #"^\s*(?:[-*+]|\d+\.)(?=\s)"#, 0),
                    (.variable, #"!?\[[^\]\n]+\]\([^)\n]+\)"#, 0),
                    (.keyword, #"\*\*[^*\n]+\*\*|__[^_\n]+__"#, 0),
                    (.builtin, #"(?<![*\w])\*[^*\s][^*\n]*\*(?!\*)"#, 0),
                ])

        case .javascript:
            return cStyle(
                keywords: "break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield async await interface type enum implements private public protected readonly as",
                constants: "true false null undefined NaN Infinity",
                extraRegions: [(.string, "`(?:[^`\\\\]|\\\\.)*`")])

        case .cLike:
            return cStyle(
                keywords: "auto break case char const continue default do double else enum extern float for goto if inline int long register return short signed sizeof static struct switch typedef union unsigned void volatile while class namespace template typename public private protected virtual override new delete this throw try catch using bool import package extends implements interface final abstract synchronized throws instanceof var val fun object",
                constants: "true false null nullptr NULL",
                extraRules: [(.attribute, #"^\s*#\s*\w+"#, 0), (.attribute, #"@\w+"#, 0)])

        case .go:
            return cStyle(
                keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
                constants: "true false nil iota",
                extraRegions: [(.string, "`[^`]*`")])

        case .rust:
            return cStyle(
                keywords: "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while",
                constants: "true false None Some Ok Err",
                extraRules: [(.attribute, #"#!?\[[^\]\n]*\]"#, 0), (.function, #"\b\w+!"#, 0)])

        case .swift:
            return cStyle(
                keywords: "actor any associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough fileprivate for func guard if import in init inout internal is let nonisolated open operator private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws try typealias var where while",
                constants: "true false nil",
                extraRegions: [(.string, "\"\"\"[\\s\\S]*?\"\"\"")],
                extraRules: [(.attribute, #"@\w+"#, 0)])

        case .php:
            return Grammar(
                regions: [(.comment, slashComments), (.comment, #"#[^\n]*"#), (.string, dq), (.string, sq)],
                rules: [
                    (.attribute, #"<\?php|\?>"#, 0),
                    (.variable, #"\$\w+"#, 0),
                    (.keyword, words("abstract and array as break case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global if implements include include_once instanceof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while yield"), 0),
                    (.constant, words("true false null TRUE FALSE NULL"), 0),
                    (.number, number, 0),
                    (.function, #"\b([a-z_]\w*)\s*(?=\()"#, 1),
                ])

        case .ruby:
            return Grammar(
                regions: [(.comment, #"#[^\n]*"#), (.string, dq), (.string, sq)],
                rules: [
                    (.keyword, words("alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_accessor attr_reader"), 0),
                    (.constant, words("true false nil"), 0),
                    (.constant, #"(?<![:\w]):\w+"#, 0),
                    (.variable, #"@{1,2}\w+|\$\w+"#, 0),
                    (.type, capitalizedType, 0),
                    (.number, number, 0),
                ])

        case .lua:
            return Grammar(
                regions: [(.comment, #"--\[\[[\s\S]*?\]\]"#), (.comment, "--[^\\n]*"), (.string, #"\[\[[\s\S]*?\]\]"#), (.string, dq), (.string, sq)],
                rules: [
                    (.keyword, words("and break do else elseif end for function goto if in local not or repeat return then until while"), 0),
                    (.constant, words("true false nil"), 0),
                    (.number, number, 0),
                    (.function, #"\b([A-Za-z_][\w.:]*)\s*(?=\()"#, 1),
                ])

        case .sql:
            return Grammar(
                regions: [(.comment, "--[^\\n]*"), (.comment, #"/\*[\s\S]*?\*/"#), (.string, "'(?:[^']|'')*'"), (.key, #""[^"\n]*"|`[^`\n]*`"#)],
                rules: [
                    (.keyword, words("select from where and or not insert into values update set delete create table drop alter add column index view join left right inner outer full on as group by order having limit offset union all distinct case when then else end primary key foreign references default unique if exists begin commit rollback grant revoke database schema with returning like in is between", caseInsensitive: true), 0),
                    (.type, words("int integer bigint smallint serial text varchar char boolean bool date time timestamp timestamptz json jsonb uuid float double numeric decimal blob", caseInsensitive: true), 0),
                    (.constant, words("null true false", caseInsensitive: true), 0),
                    (.number, number, 0),
                ])

        case .dockerfile:
            return Grammar(
                regions: [(.comment, #"^\s*#[^\n]*"#), (.string, dq), (.string, sq)],
                rules: [
                    (.keyword, #"(?i)^\s*(?:FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b"#, 0),
                    (.keyword, #"(?i)\bAS\b"#, 0),
                    (.variable, #"\$\{?[A-Za-z_]\w*\}?"#, 0),
                    (.attribute, #"(?<=\s)--[\w-]+(?:=\S*)?"#, 0),
                ])

        case .nginx:
            return Grammar(
                regions: [(.comment, hashComment), (.string, dq), (.string, sq)],
                rules: [
                    (.keyword, #"^\s*(?:server|location|http|events|upstream|stream|if|map|types|geo|limit_except)\b"#, 0),
                    (.key, #"^\s*([a-z_][a-z0-9_]*)(?=\s)"#, 1),
                    (.variable, #"\$\w+"#, 0),
                    (.constant, words("on off"), 0),
                    (.number, #"(?<![\w.$])\d+[kKmMgGsShHdDwy]?(?![\w.])"#, 0),
                ])

        case .css:
            return Grammar(
                regions: [(.comment, #"/\*[\s\S]*?\*/"#), (.string, dq), (.string, sq)],
                rules: [
                    (.keyword, #"@[\w-]+"#, 0),
                    (.key, #"([\w-]+)(?=\s*:[^{;]*;)"#, 1),
                    (.number, #"#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b"#, 0),
                    (.variable, #"--[\w-]+|\$[\w-]+"#, 0),
                    (.tag, #"[.#][A-Za-z_][\w-]*(?=[^{}]*\{)"#, 0),
                ])

        case .makefile:
            return Grammar(
                regions: [(.comment, #"(?:^|(?<=\s))#[^\n]*"#)],
                rules: [
                    (.keyword, #"^\s*(?:ifeq|ifneq|ifdef|ifndef|else|endif|include|-include|define|endef|export|override)\b"#, 0),
                    (.section, #"^[A-Za-z0-9_./%$() -]+(?=:(?!=))"#, 0),
                    (.variable, #"\$[({][^)}\n]+[)}]|\$[@<^?*%]"#, 0),
                    (.key, #"^[A-Za-z_][\w.]*(?=\s*[:+?]?=)"#, 0),
                ])
        }
    }
}
