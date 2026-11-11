import AXAskpassProtocol
@testable import AXSSH
import AXStorage
import Foundation
import Testing

@Suite struct AskpassPromptTests {
    @Test(arguments: [
        ("root@10.0.0.1's password: ", nil, AskpassPromptKind.password),
        ("(root@10.0.0.1) Password: ", nil, .password),
        ("Password:", nil, .password),
        ("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ", nil, .passphrase(keyPath: "/Users/me/.ssh/id_ed25519")),
        ("Enter passphrase for /Users/me/.ssh/id_rsa:", nil, .passphrase(keyPath: "/Users/me/.ssh/id_rsa")),
        ("The authenticity of host 'x (1.2.3.4)' can't be established.\nED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ", nil, .hostKeyConfirmation),
        ("Allow use of key?", "confirm", .confirm),
        ("Confirm user presence", "none", .notice),
        ("Verification code: ", nil, .other),
    ] as [(String, String?, AskpassPromptKind)])
    func classifies(prompt: String, hint: String?, expected: AskpassPromptKind) {
        #expect(AskpassPrompt.classify(prompt, hint: hint) == expected)
    }

    @Test func autofillOnlyForOwnHost() {
        func check(_ prompt: String, hosts: [String] = ["web", "10.0.0.1"], user: String? = "root", jump: Bool = false) -> Bool {
            AskpassPrompt.shouldAutofillPassword(prompt: prompt, hostCandidates: hosts, user: user, hasJumpHost: jump)
        }
        #expect(check("root@10.0.0.1's password: "))
        #expect(check("(root@10.0.0.1) Password: "))
        #expect(check("root@WEB's password: "))
        #expect(!check("admin@bastion's password: ", jump: true))
        #expect(!check("deploy@10.0.0.1's password: "))
        #expect(check("Password:"))
        #expect(!check("Password:", jump: true))
        #expect(!check("Verification code:"))
        #expect(check("x@10.0.0.1's password: ", user: nil))
    }
}

@Suite struct ResolvedConfigTests {
    @Test func parsesSSHGOutput() {
        let out = """
        user root
        hostname 147.0.0.1
        port 2222
        proxyjump none
        identityfile ~/.ssh/id_ed25519
        """
        #expect(ResolvedSSHConfig.parse(out) == ResolvedSSHConfig(hostName: "147.0.0.1", user: "root", port: 2222))
        #expect(ResolvedSSHConfig.parse("proxyjump a@b\n").proxyJump == "a@b")
    }

    @Test func realSSHGResolvesAlias() async throws {
        // `ssh -G` never connects, so this is safe to run anywhere.
        let resolved = try #require(await SSHConfigResolver.resolve(
            sshPath: "/usr/bin/ssh", arguments: ["-p", "2200", "-l", "tester", "--", "example.invalid"]))
        #expect(resolved.hostName == "example.invalid")
        #expect(resolved.port == 2200)
        #expect(resolved.user == "tester")
    }
}

@Suite struct AskpassBrokerTests {
    /// End-to-end through the real Unix socket, the way abx-askpass talks to the app.
    @Test func socketRoundTripUsesPresenter() async throws {
        let socket = "/tmp/abx-test-\(getpid())-\(Int.random(in: 0..<100_000)).sock"
        let keychain = KeychainStore(service: "com.mikhail.AbobaXTerm.tests.\(UUID().uuidString)")
        let broker = try AskpassBroker(socketPath: socket, keychain: keychain) { question in
            switch question.kind {
            case .hostKeyConfirmation: AskpassAnswer(value: "", save: false)
            case .other: AskpassAnswer(value: "123456", save: false)
            default: nil
            }
        }
        defer { broker.stop() }
        let token = broker.register(AskpassContext(
            sessionID: UUID(), sessionName: "t", hostCandidates: ["h"], user: "u",
            hasJumpHost: false, canSavePassword: false))

        func send(_ prompt: String, token: String) throws -> AskpassResponse {
            let fd = try UnixSocket.connect(path: socket)
            defer { close(fd) }
            try UnixSocket.writeAll(fd: fd, data: AskpassCodec.encodeLine(AskpassRequest(token: token, prompt: prompt, hint: nil)))
            return try AskpassCodec.decodeLine(AskpassResponse.self, from: UnixSocket.readLine(fd: fd))
        }

        #expect(try send("Are you sure you want to continue connecting (yes/no)?", token: token).answer == "yes")
        #expect(try send("Verification code:", token: token).answer == "123456")
        #expect(try send("u@h's password:", token: token).answer == nil) // presenter cancels
        #expect(try send("Verification code:", token: "bogus").answer == nil)

        broker.unregister(token)
        #expect(try send("Verification code:", token: token).answer == nil)
    }
}
