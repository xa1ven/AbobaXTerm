@testable import AXTerminal
import Testing

@Suite struct OutputHighlighterTests {
    let esc = "\u{1B}"

    func run(_ chunks: [String], flush: Bool = true) -> String {
        let h = OutputHighlighter()
        var out: [UInt8] = []
        for chunk in chunks { out += h.process(Array(chunk.utf8)) }
        if flush { out += h.flush() }
        return String(decoding: out, as: UTF8.self)
    }

    /// Removes escape sequences: output text must never change.
    func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    @Test func colorsIPv4ButNotZeroAddress() {
        let out = run(["from 147.45.178.199 port 22, listen 0.0.0.0:22\r\n"])
        #expect(out.contains("\(esc)[95m147.45.178.199\(esc)[39m"))
        #expect(out.contains(" 0.0.0.0:22"))
        #expect(strip(out) == "from 147.45.178.199 port 22, listen 0.0.0.0:22\r\n")
    }

    @Test func ipAtEndOfSentenceAndVersionsAreHandled() {
        #expect(run(["from 10.0.0.1.\r\n"]).contains("\(esc)[95m10.0.0.1\(esc)[39m."))
        #expect(!run(["version 1.2.3.4.5\r\n"]).contains("\(esc)[95m"))
    }

    @Test func statusWordsAndPhrases() {
        let out = run(["Active: active (running) since Thu; Invalid user admin; Connection closed by\r\n"])
        #expect(out.contains("\(esc)[92mactive (running)\(esc)[39m"))
        #expect(out.hasPrefix("Active: "))
        #expect(out.contains("\(esc)[91mInvalid\(esc)[39m"))
        #expect(out.contains("\(esc)[93mConnection closed\(esc)[39m"))
    }

    @Test func pidURLAndOptions() {
        let out = run(["sshd[72648]: see https://ubuntu.com/esm or apt list --upgradable\r\n"])
        #expect(out.contains("sshd[\(esc)[94m72648\(esc)[39m]"))
        #expect(out.contains("\(esc)[4mhttps://ubuntu.com/esm\(esc)[24m"))
        #expect(out.contains("\(esc)[36m--upgradable\(esc)[39m"))
    }

    @Test func shortAndLongFlags() {
        let out = run(["docker ps -a --format=json; ls -la /tmp; date 2026-11-05 a - b\r\n"])
        #expect(out.contains(" \(esc)[36m-a\(esc)[39m "))
        #expect(out.contains("\(esc)[36m--format=json\(esc)[39m"))
        #expect(out.contains("\(esc)[36m-la\(esc)[39m"))
        #expect(out.contains("2026-11-05"))
        #expect(out.contains(" a - b"))
    }

    @Test func flagIsColoredWhileTyping() {
        // Prompt, then the shell echoes typed characters one by one.
        let out = run(["root@vps:~# ", "d", "o", "c", "k", "e", "r", " ", "p", "s", " ", "-", "a"], flush: false)
        #expect(out.hasSuffix(" \(esc)[36m-\(esc)[39m\(esc)[36ma\(esc)[39m"))
        #expect(strip(out) == "root@vps:~# docker ps -a")
    }

    @Test func backspaceKeepsContextInSync() {
        // Type "-x", erase "x" ("\b \b" as readline does), type "a".
        let out = run(["$ ls -", "x", "\u{08} \u{08}", "a"], flush: false)
        #expect(out.hasSuffix("\(esc)[36ma\(esc)[39m"))
    }

    @Test func ipIsColoredWhileTyping() {
        let typed = ["$ ping "] + "10.0.0.1".map { String($0) }
        let out = run(typed, flush: false)
        #expect(out.hasSuffix("\(esc)[95m1\(esc)[39m"))
    }

    @Test func timesAreNotIPv6() {
        let out = run(["Nov 11 00:37:52 host [::1]:6010\r\n"])
        #expect(out.contains("00:37:52 "))
        #expect(!out.contains("\(esc)[96m00"))
        #expect(out.contains("\(esc)[96m[::1]\(esc)[39m"))
    }

    @Test func programColorsAreRespected() {
        // Already colored by the program (e.g. systemctl): left alone.
        let out = run(["\(esc)[0;1;31mfailed 10.0.0.1\(esc)[0m ok\r\n"])
        #expect(out.hasPrefix("\(esc)[0;1;31mfailed 10.0.0.1\(esc)[0m"))
        #expect(out.contains("\(esc)[92mok\(esc)[39m"))
    }

    @Test func extendedColorsAreParsed() {
        let out = run(["\(esc)[38;5;196merror\(esc)[39m error\r\n"])
        #expect(out.hasPrefix("\(esc)[38;5;196merror\(esc)[39m"))
        #expect(out.contains(" \(esc)[91merror\(esc)[39m"))
    }

    @Test func alternateScreenIsUntouched() {
        let out = run(["\(esc)[?1049herror 10.0.0.1\(esc)[?1049l error\r\n"])
        #expect(out.contains("\(esc)[?1049herror 10.0.0.1\(esc)[?1049l"))
        #expect(out.contains(" \(esc)[91merror\(esc)[39m"))
    }

    @Test func oscTitleIsNotHighlighted() {
        let out = run(["\(esc)]0;root@10.0.0.1: ~\u{07}10.0.0.2\r\n"])
        #expect(out.hasPrefix("\(esc)]0;root@10.0.0.1: ~\u{07}"))
        #expect(out.contains("\(esc)[95m10.0.0.2\(esc)[39m"))
    }

    @Test func wordSplitAcrossBulkChunksStillMatches() {
        let padding = String(repeating: "x ", count: 200)
        let out = run([padding + "from 192.168.", "1.10 done\r\n"])
        #expect(out.contains("\(esc)[95m192.168.1.10\(esc)[39m"))
        #expect(strip(out) == padding + "from 192.168.1.10 done\r\n")
    }

    @Test func smallChunksAreNotDelayed() {
        let h = OutputHighlighter()
        let out = String(decoding: h.process(Array("l".utf8)), as: UTF8.self)
        #expect(out == "l")
        #expect(!h.hasPendingOutput)
    }

    @Test func utf8SplitAcrossChunksIsPreserved() {
        let bytes = Array("Привет 10.0.0.1".utf8)
        let h = OutputHighlighter()
        var out = h.process(bytes[0..<3]) // splits the second Cyrillic letter
        out += h.process(bytes[3...])
        out += h.flush()
        let text = String(decoding: out, as: UTF8.self)
        #expect(strip(text) == "Привет 10.0.0.1")
        #expect(!text.contains("\u{FFFD}"))
    }

    @Test func binaryGarbagePassesThroughUnchanged() {
        let garbage: [UInt8] = [0xFF, 0xFE, 0x41, 0x20, 0xC3, 0x28]
        let h = OutputHighlighter()
        let out = h.process(garbage) + h.flush()
        #expect(out == garbage)
    }

    @Test func disabledHighlighterIsTransparent() {
        let h = OutputHighlighter()
        h.isEnabled = false
        let input = Array("error 10.0.0.1\r\n".utf8)
        #expect(h.process(input) + h.flush() == input)
    }
}
