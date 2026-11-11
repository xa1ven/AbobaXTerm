@testable import AXEditor
import Foundation
import Testing

@Suite struct SyntaxHighlighterTests {
    /// Text of every token of `kind`.
    func texts(_ kind: TokenKind, in source: String, _ language: SyntaxLanguage) -> [String] {
        let ns = source as NSString
        return SyntaxHighlighter(language: language).tokens(in: source)
            .filter { $0.kind == kind }
            .map { ns.substring(with: $0.range) }
    }

    @Test(arguments: SyntaxLanguage.allCases)
    func everyGrammarCompilesAndHandlesEdgeInput(_ language: SyntaxLanguage) {
        let h = SyntaxHighlighter(language: language)
        _ = h.tokens(in: "")
        _ = h.tokens(in: "\"unterminated 'mix /* # -- <!-- ``` \n\n\t")
        // Tokens never overlap and stay in bounds.
        let sample = "# c\nkey: \"v\" 42 // x\n<a b=\"c\">$VAR</a>\n"
        let tokens = h.tokens(in: sample)
        var end = 0
        for t in tokens {
            #expect(t.range.location >= end)
            end = NSMaxRange(t.range)
        }
        #expect(end <= (sample as NSString).length)
    }

    @Test func detection() {
        #expect(SyntaxLanguage.detect(fileName: "deploy.sh", content: "") == .shell)
        #expect(SyntaxLanguage.detect(fileName: "run", content: "#!/usr/bin/env python3\n") == .python)
        #expect(SyntaxLanguage.detect(fileName: "Dockerfile.prod", content: "") == .dockerfile)
        #expect(SyntaxLanguage.detect(fileName: "site.conf", content: "server {\n listen 80;\n}") == .nginx)
        #expect(SyntaxLanguage.detect(fileName: "my.conf", content: "a = 1") == .ini)
        #expect(SyntaxLanguage.detect(fileName: "docker-compose.yml", content: "") == .yaml)
        #expect(SyntaxLanguage.detect(fileName: "sshd_config", content: "") == .ini)
        #expect(SyntaxLanguage.detect(fileName: ".bashrc", content: "") == .shell)
        #expect(SyntaxLanguage.detect(fileName: "notes", content: "hello") == .plain)
    }

    @Test func shellCommentsStringsAndVariables() {
        let src = "echo \"a # not comment\" $HOME ${X} # real\nls -la\n"
        #expect(texts(.comment, in: src, .shell) == ["# real"])
        #expect(texts(.string, in: src, .shell) == ["\"a # not comment\""])
        #expect(texts(.variable, in: src, .shell) == ["$HOME", "${X}"])
        #expect(texts(.builtin, in: src, .shell) == ["echo"])
        #expect(texts(.attribute, in: src, .shell) == ["-la"])
    }

    @Test func shellHashInsideWordIsNotComment() {
        #expect(texts(.comment, in: "echo ${#arr} a#b\n", .shell).isEmpty)
    }

    @Test func pythonTripleQuotesAndKeywords() {
        let src = "def f(x):\n    \"\"\"doc # x\"\"\"\n    return None  # done\n"
        #expect(texts(.string, in: src, .python) == ["\"\"\"doc # x\"\"\""])
        #expect(texts(.comment, in: src, .python) == ["# done"])
        #expect(texts(.keyword, in: src, .python) == ["def", "return"])
        #expect(texts(.function, in: src, .python) == ["f"])
        #expect(texts(.constant, in: src, .python) == ["None"])
    }

    @Test func jsonKeysVsValues() {
        let src = #"{"name": "web", "port": 8080, "on": true}"#
        #expect(texts(.key, in: src, .json) == [#""name""#, #""port""#, #""on""#])
        #expect(texts(.string, in: src, .json) == [#""web""#])
        #expect(texts(.number, in: src, .json) == ["8080"])
        #expect(texts(.constant, in: src, .json) == ["true"])
    }

    @Test func yamlKeys() {
        let src = "services:\n  web:\n    image: \"nginx:latest\" # pinned\n    - name: x\n    ports: [80]\n"
        #expect(texts(.key, in: src, .yaml) == ["services", "web", "image", "name", "ports"])
        #expect(texts(.comment, in: src, .yaml) == ["# pinned"])
        #expect(texts(.string, in: src, .yaml) == ["\"nginx:latest\""])
    }

    @Test func iniAndSSHConfig() {
        let src = "[Unit]\nDescription=My app\n# comment\nPermitRootLogin prohibit-password\nPort 22\n"
        #expect(texts(.section, in: src, .ini) == ["[Unit]"])
        #expect(texts(.key, in: src, .ini) == ["Description", "PermitRootLogin", "Port"])
        #expect(texts(.comment, in: src, .ini) == ["# comment"])
        #expect(texts(.number, in: src, .ini) == ["22"])
    }

    @Test func xmlTagsAndAttributes() {
        let src = #"<!-- c --><server port="80"><name>x</name></server>"#
        #expect(texts(.comment, in: src, .xml) == ["<!-- c -->"])
        #expect(texts(.tag, in: src, .xml) == ["server", "name", "name", "server"])
        #expect(texts(.attribute, in: src, .xml) == ["port"])
        #expect(texts(.string, in: src, .xml) == [#""80""#])
    }

    @Test func cStyleCommentsDoNotLeak() {
        let src = "int main() { /* if */ return \"//x\"; } // end\n"
        #expect(texts(.comment, in: src, .cLike) == ["/* if */", "// end"])
        #expect(texts(.keyword, in: src, .cLike) == ["int", "return"])
        #expect(texts(.string, in: src, .cLike) == ["\"//x\""])
    }

    @Test func nginxDirectives() {
        let src = "server {\n    listen 443 ssl;\n    root $document_root; # web\n}\n"
        #expect(texts(.keyword, in: src, .nginx) == ["server"])
        #expect(texts(.key, in: src, .nginx) == ["listen", "root"])
        #expect(texts(.variable, in: src, .nginx) == ["$document_root"])
        #expect(texts(.comment, in: src, .nginx) == ["# web"])
    }
}
