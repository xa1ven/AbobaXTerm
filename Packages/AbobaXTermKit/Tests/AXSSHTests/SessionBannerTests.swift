@testable import AXSSH
import AXModels
import Foundation
import Testing

@Suite struct SessionBannerTests {
    func banner(_ session: Session, _ edit: (inout SessionBanner.Context) -> Void = { _ in }) -> SessionBanner {
        var resolved = ResolvedSSHConfig(hostName: session.host, user: "root", port: session.port ?? 22)
        resolved.compression = false
        var context = SessionBanner.Context(appVersion: "1.2.3", resolved: resolved)
        context.isSaved = false
        edit(&context)
        return SessionBanner(session: session, context: context)
    }

    func value(_ banner: SessionBanner, _ label: String) -> SessionBanner.Row? {
        banner.rows.first { $0.label == label }
    }

    @Test func describesAPlainKeySession() {
        let b = banner(Session(host: "10.0.0.5", auth: .publicKey(path: "~/.ssh/id_ed25519"))) { $0.keyComment = "me@mac" }
        #expect(b.title == "AbobaXTerm 1.2.3")
        #expect(b.destination == "root@10.0.0.5")
        #expect(b.note == nil)
        #expect(value(b, "Route")?.value == "direct")
        #expect(value(b, "Sign-in")?.value == "key id_ed25519 (me@mac)")
        #expect(value(b, "Connection") == nil)
        #expect(value(b, "Compression")?.mark == .off)
        #expect(value(b, "X11")?.mark == .off)
        #expect(value(b, "Monitoring")?.mark == .on)
        #expect(value(b, "Last visit") == nil)
    }

    @Test func jumpHostPortSharedConnectionAndX11() {
        let session = Session(host: "db", port: 2222, auth: .password, jumpHost: "bastion", x11Forwarding: true)
        let b = banner(session) {
            $0.resolved?.hostName = "db.internal"
            $0.isShared = true
            $0.x11Ready = false
            $0.isSaved = true
        }
        #expect(b.note == "db.internal, port 2222")
        #expect(value(b, "Route")?.value == "through bastion")
        #expect(value(b, "Sign-in")?.value == "password")
        #expect(value(b, "Connection")?.value == "shared with a tab that is already open")
        #expect(value(b, "X11")?.mark == .failed)
        #expect(value(b, "Last visit")?.value == "first time")
    }

    @Test func frameLinesHaveTheSameWidth() {
        let text = banner(Session(host: "10.0.0.5", auth: .system)).render(columns: 100, color: false)
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.first?.hasPrefix(" ╭─ AbobaXTerm 1.2.3 ─") == true)
        #expect(lines.last?.hasPrefix(" ╰─") == true)
        #expect(Set(lines.map(\.count)).count == 1)
        #expect(lines.contains { $0.contains("▸ root@10.0.0.5") })
    }

    @Test func longValuesAreCutToTheTerminal() {
        let session = Session(host: "h", auth: .publicKey(path: "/keys/" + String(repeating: "k", count: 90)))
        let lines = banner(session).render(columns: 60, color: false).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(Set(lines.map(\.count)).count == 1)
        #expect((lines.first?.count ?? 0) <= 60)
        #expect(lines.contains { $0.contains("…") })
    }

    @Test func narrowTerminalGetsNoFrame() {
        let text = banner(Session(host: "h", auth: .system)).render(columns: 40, color: false)
        #expect(!text.contains("│"))
        #expect(text.hasPrefix("AbobaXTerm 1.2.3\r\n▸ root@h"))
    }

    @Test func colorOnlyAddsEscapeSequences() {
        let b = banner(Session(host: "h", auth: .system))
        let stripped = b.render(columns: 80).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        #expect(stripped == b.render(columns: 80, color: false))
    }

    @Test func keyComment() {
        #expect(SessionBanner.keyComment(publicKeyFile: "ssh-ed25519 AAAAC3Nza me@my mac\n") == "me@my mac")
        #expect(SessionBanner.keyComment(publicKeyFile: "ssh-ed25519 AAAAC3Nza\n") == nil)
    }

    @Test func resolvedConfigReadsCompressionAndLocalCommand() {
        let parsed = ResolvedSSHConfig.parse("hostname h\ncompression yes\nlocalcommand echo hi there\n")
        #expect(parsed.compression == true)
        #expect(parsed.localCommand == "echo hi there")
        #expect(ResolvedSSHConfig.parse("compression no\n").localCommand == nil)
    }

    @Test func installBannerAddsLocalCommandBeforeTheHost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let launcher = SSHLauncher(builder: SSHCommandBuilder(controlDirectory: dir.path), broker: nil, askpassHelperPath: nil)
        var spec = SSHLaunchSpec(executable: "/usr/bin/ssh", arguments: ["-p", "22", "--", "host"], environment: [],
                                 askpassToken: nil, commandLine: "")
        try launcher.installBanner("hello\r\n", in: &spec)
        let file = try #require(spec.bannerFile)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "hello\r\n")
        #expect(spec.arguments.suffix(2) == ["--", "host"])
        #expect(spec.arguments.contains("PermitLocalCommand=yes"))
        #expect(spec.arguments.contains { $0.hasPrefix("LocalCommand=/bin/cat ") && $0.contains(file) })
        launcher.finish(spec)
        #expect(!FileManager.default.fileExists(atPath: file))
    }
}
