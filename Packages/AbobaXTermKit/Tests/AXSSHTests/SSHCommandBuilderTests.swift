import AXModels
@testable import AXSSH
import Foundation
import Testing

@Suite struct SSHCommandBuilderTests {
    let builder = SSHCommandBuilder(controlDirectory: "/tmp/abx-501", controlPersistSeconds: 600)

    @Test func minimalSessionLeavesEverythingToSSHConfig() throws {
        let s = Session(host: "myalias")
        let args = try builder.arguments(for: s)
        #expect(args.suffix(2) == ["--", "myalias"])
        #expect(!args.contains("-p"))
        #expect(!args.contains("-l"))
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains("ControlPersist=600"))
    }

    @Test func controlPathIsShortAndPerSession() throws {
        let s = Session(id: UUID(uuidString: "ABCDEF01-0000-0000-0000-000000000000")!, host: "h")
        let path = builder.controlPath(for: s)
        #expect(path == "/tmp/abx-501/cm-abcdef01-%C")
        // %C expands to 40 hex chars; ssh adds ".XXXXXXXXXXXXXXXX" while binding.
        #expect(path.utf8.count - 2 + 40 + 17 < 104)
    }

    @Test func fullSession() throws {
        let s = Session(host: "10.0.0.5", port: 2222, user: "root", auth: .publicKey(path: "~/.ssh/id_ed25519"),
                        jumpHost: "admin@bastion:22", extraOptions: #"-o ServerAliveInterval=30 -o "SetEnv=A=b c""#,
                        x11Forwarding: true)
        let args = try builder.arguments(for: s)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(args.containsSequence(["-p", "2222"]))
        #expect(args.containsSequence(["-l", "root"]))
        #expect(args.containsSequence(["-i", "\(home)/.ssh/id_ed25519", "-o", "IdentitiesOnly=yes"]))
        #expect(args.containsSequence(["-J", "admin@bastion:22"]))
        #expect(args.contains("-Y"))
        #expect(args.containsSequence(["-o", "ServerAliveInterval=30", "-o", "SetEnv=A=b c"]))
        #expect(args.suffix(2) == ["--", "10.0.0.5"])
    }

    @Test func x11UsesXQuartzXauthAndItsOwnMaster() throws {
        let b = SSHCommandBuilder(controlDirectory: "/tmp/abx-501", xauthPath: "/opt/X11/bin/xauth")
        let id = UUID(uuidString: "ABCDEF01-0000-0000-0000-000000000000")!
        let x = Session(id: id, host: "srv", x11Forwarding: true)
        let plain = Session(id: id, host: "srv")
        let args = try b.arguments(for: x)
        #expect(args.containsSequence(["-Y", "-o", "XAuthLocation=/opt/X11/bin/xauth"]))
        #expect(!(try b.arguments(for: plain)).contains("XAuthLocation=/opt/X11/bin/xauth"))
        #expect(b.controlPath(for: x) == "/tmp/abx-501/cm-abcdef01-x-%C")
        #expect(b.controlPath(for: plain) == "/tmp/abx-501/cm-abcdef01-%C")
        // Both share the prefix used to close masters on quit.
        #expect(b.controlPath(for: x).contains("/" + SSHCommandBuilder.controlSocketName(for: x)))
    }

    @Test func muxArgumentsReuseMasterWithoutX11() throws {
        let s = Session(host: "srv", port: 2200, user: "me", x11Forwarding: true)
        let sftp = try builder.muxArguments(for: s, subsystem: "sftp")
        #expect(sftp.contains("ControlMaster=no"))
        #expect(!sftp.contains("ControlMaster=auto"))
        #expect(sftp.contains("ControlPath=\(builder.controlPath(for: s))"))
        #expect(!sftp.contains("-Y"))
        #expect(sftp.contains("BatchMode=yes"))
        #expect(sftp.suffix(4) == ["-s", "--", "srv", "sftp"])

        let exec = try builder.muxArguments(for: s, command: ["uptime"])
        #expect(exec.suffix(3) == ["--", "srv", "uptime"])
        #expect(!exec.contains("-s"))

        let check = try builder.checkArguments(for: s)
        #expect(check.prefix(2) == ["-O", "check"])
        #expect(check.contains("2200") && check.suffix(2) == ["--", "srv"])
    }

    @Test func passwordAuthPrefersInteractiveMethods() throws {
        let args = try builder.arguments(for: Session(host: "h", auth: .password))
        #expect(args.contains("PreferredAuthentications=keyboard-interactive,password"))
    }

    @Test func rejectsOptionInjectionAndBadInput() {
        #expect(throws: SSHCommandBuilder.BuildError.emptyHost) { try builder.arguments(for: Session(host: " ")) }
        #expect(throws: SSHCommandBuilder.BuildError.invalidHost("-oProxyCommand=x")) {
            try builder.arguments(for: Session(host: "-oProxyCommand=x"))
        }
        #expect(throws: SSHCommandBuilder.BuildError.invalidPort(0)) { try builder.arguments(for: Session(host: "h", port: 0)) }
        #expect(throws: SSHCommandBuilder.BuildError.invalidKeyPath) {
            try builder.arguments(for: Session(host: "h", auth: .publicKey(path: "")))
        }
        #expect(throws: (any Error).self) { try builder.arguments(for: Session(host: "h", extraOptions: "-o 'oops")) }
    }

    @Test func commandLineIsQuoted() {
        let line = builder.commandLine(for: Session(host: "h", extraOptions: #"-o "SetEnv=A=b c""#))
        #expect(line.hasPrefix("ssh -o ControlMaster=auto"))
        #expect(line.contains("'SetEnv=A=b c'"))
        #expect(line.hasSuffix("-- h"))
    }
}

@Suite struct ShellWordsTests {
    @Test(arguments: [
        ("", []),
        ("a b  c", ["a", "b", "c"]),
        (#"-o 'A B' "C \"D\"" e\ f"#, ["-o", "A B", #"C "D""#, "e f"]),
        ("''", [""]),
        (#"a"b"'c'"#, ["abc"]),
    ] as [(String, [String])])
    func splits(input: String, expected: [String]) throws {
        #expect(try ShellWords.split(input) == expected)
    }

    @Test func errors() {
        #expect(throws: ShellWords.ParseError.unterminatedQuote("'")) { try ShellWords.split("'abc") }
        #expect(throws: ShellWords.ParseError.trailingBackslash) { try ShellWords.split("abc\\") }
    }

    @Test func quoteRoundTrip() throws {
        let words = ["ssh", "a b", "it's", "", "x=y"]
        #expect(try ShellWords.split(ShellWords.join(words)) == words)
    }
}

extension Array where Element: Equatable {
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard sequence.count <= count else { return false }
        return (0...(count - sequence.count)).contains { Array(self[$0..<$0 + sequence.count]) == sequence }
    }
}
