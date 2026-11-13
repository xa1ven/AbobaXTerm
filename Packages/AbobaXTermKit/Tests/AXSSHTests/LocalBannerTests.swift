@testable import AXSSH
import Foundation
import Testing

@Suite struct LocalBannerTests {
    func banner(_ agent: LocalBanner.AgentKeys = .count(2), ssh: String? = "OpenSSH 9.9") -> LocalBanner {
        LocalBanner(appVersion: "1.2.3", facts: .init(shell: "zsh", term: "xterm-256color", sshVersion: ssh, agentKeys: agent))
    }

    func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    @Test func describesShellAndSSH() {
        let rows = banner().groups[0]
        #expect(rows[0] == .init("Shell", "zsh (login), TERM xterm-256color"))
        #expect(rows[1] == .init("SSH", "OpenSSH 9.9, 2 keys in agent"))
        #expect(banner(.count(1)).groups[0][1].lines[0][0].text == "OpenSSH 9.9, 1 key in agent")
        #expect(banner(.count(0)).groups[0][1].lines[0][0].text == "OpenSSH 9.9, no keys in agent")
        #expect(banner(.noAgent).groups[0][1].lines[0][0].text == "OpenSSH 9.9, ssh-agent is not running")
        // Nothing known about ssh: no row at all.
        #expect(banner(.unknown, ssh: nil).groups[0].count == 1)
    }

    @Test func framedLinesHaveOneWidthAndAlignedColumns() {
        let all = lines(banner().render(columns: 100, color: false))
        #expect(Set(all.map(\.count)).count == 1)
        #expect(all.first?.hasPrefix(" ╭─") == true)
        #expect(all.last?.hasSuffix("─╯") == true)
        #expect(all[1].contains("• AbobaXTerm 1.2.3 •"))
        #expect(all.contains { $0.contains("▸ Shell  zsh (login)") })
        #expect(all.contains { $0.contains("More information: https://abobaxterm.site") })
        // The second column of the shortcut lines starts at the same place.
        let first = try! #require(all.first { $0.contains("⌘N new session") })
        let second = try! #require(all.first { $0.contains("⇧⌘[ ⇧⌘] previous / next") })
        #expect(first.distance(from: first.startIndex, to: first.range(of: "⌘N")!.lowerBound)
                == second.distance(from: second.startIndex, to: second.range(of: "⇧⌘[")!.lowerBound))
    }

    @Test func noticeIsWrappedInsideTheFrame() {
        let all = lines(banner().render(columns: 70, color: false))
        #expect(all.allSatisfy { $0.count <= 70 })
        #expect(all.filter { $0.contains("Mobatek") }.count == 1)
        #expect(LocalBanner.wrap("aa bb cc", width: 5) == ["aa bb", "cc"])
    }

    @Test func narrowTerminalGetsPlainLines() {
        let text = banner().render(columns: 40, color: false)
        #expect(!text.contains("│") && !text.contains("╭"))
        #expect(text.contains("⌘T local terminal"))
        #expect(text.contains("https://abobaxterm.site"))
    }

    @Test func linkIsAnExplicitHyperlink() {
        let text = banner().render(columns: 100)
        #expect(text.contains("\u{1B}]8;;https://abobaxterm.site\u{1B}\\"))
        #expect(text.contains("\u{1B}]8;;\u{1B}\\"))
    }

    @Test func readsSSHVersionAndAgent() {
        #expect(LocalBanner.sshVersion(fromOutput: "OpenSSH_9.9p2, LibreSSL 3.3.6\n") == "OpenSSH 9.9")
        #expect(LocalBanner.sshVersion(fromOutput: "OpenSSH_10.0p1 Debian-5, OpenSSL 3.5") == "OpenSSH 10.0")
        #expect(LocalBanner.sshVersion(fromOutput: "command not found") == nil)
        #expect(LocalBanner.agentKeys(exitCode: 0, output: "256 SHA256:a me (ED25519)\n256 SHA256:b you (ED25519)\n") == .count(2))
        #expect(LocalBanner.agentKeys(exitCode: 1, output: "The agent has no identities.\n") == .count(0))
        #expect(LocalBanner.agentKeys(exitCode: 2, output: "Error connecting to agent") == .noAgent)
    }

    @Test func gathersFactsFromThisMac() async {
        let facts = await LocalBanner.gatherFacts()
        #expect(!facts.shell.isEmpty)
        #expect(facts.sshVersion?.hasPrefix("OpenSSH ") == true)
        // A command that cannot start leaves the fact unknown instead of failing.
        let none = await LocalBanner.gatherFacts(sshPath: "/nonexistent/ssh", sshAddPath: "/nonexistent/ssh-add")
        #expect(none.sshVersion == nil && none.agentKeys == .unknown)
    }
}
