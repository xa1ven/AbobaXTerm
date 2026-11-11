import AXModels
@testable import AXSSH
import AXStorage
import Foundation
import Synchronization
import Testing

/// Opt-in end-to-end test: real /usr/bin/ssh + abx-askpass + broker against a
/// throwaway local sshd. Enable with:
///   ABX_E2E_SSHD_PORT=2222 ABX_E2E_AUTHORIZED_KEYS=/path/authorized_keys \
///   ABX_E2E_HELPER=/path/abx-askpass swift test --filter AskpassEndToEnd
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ABX_E2E_SSHD_PORT"] != nil))
struct AskpassEndToEndTests {
    let env = ProcessInfo.processInfo.environment

    @Test func passphraseAndHostKeyGoThroughBroker() async throws {
        let port = try #require(Int(env["ABX_E2E_SSHD_PORT"] ?? ""))
        let authorizedKeys = try #require(env["ABX_E2E_AUTHORIZED_KEYS"])
        let helper = try #require(env["ABX_E2E_HELPER"])

        let dir = URL(fileURLWithPath: "/tmp/abx-e2e-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        // Passphrase-protected client key, authorized on the test sshd.
        let key = dir.appendingPathComponent("id_test").path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "s3cret", "-f", key])
        let pub = try String(contentsOfFile: key + ".pub", encoding: .utf8)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: authorizedKeys))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(pub.utf8))
        try handle.close()

        let asked = Mutex<[AskpassPromptKind]>([])
        let keychain = KeychainStore(service: "com.mikhail.AbobaXTerm.e2e.\(UUID().uuidString)")
        let broker = try AskpassBroker(socketPath: dir.appendingPathComponent("ap.sock").path, keychain: keychain) { q in
            asked.withLock { $0.append(q.kind) }
            switch q.kind {
            case .hostKeyConfirmation: return AskpassAnswer(value: "", save: false)
            case .passphrase: return AskpassAnswer(value: "s3cret", save: false)
            default: return nil
            }
        }
        defer { broker.stop() }

        let session = Session(
            host: "127.0.0.1", port: port, auth: .publicKey(path: key),
            extraOptions: "-o UserKnownHostsFile=\(dir.path)/known_hosts -o StrictHostKeyChecking=ask")
        let launcher = SSHLauncher(
            builder: SSHCommandBuilder(controlDirectory: dir.path, controlPersistSeconds: 5),
            broker: broker, askpassHelperPath: helper)
        let spec = try await launcher.prepare(session, isSaved: true)
        defer { launcher.finish(spec) }

        let output = try await Task.detached {
            try run(spec.executable, spec.arguments + ["echo", "e2e-ok"], environment: spec.environment)
        }.value
        #expect(output.contains("e2e-ok"))
        let kinds = asked.withLock { $0 }
        #expect(kinds.contains(.hostKeyConfirmation))
        #expect(kinds.contains(.passphrase(keyPath: key)))

        // The master is up: a second command reuses it without new prompts.
        let before = kinds.count
        let again = try run(spec.executable, spec.arguments + ["echo", "again"], environment: spec.environment)
        #expect(again.contains("again"))
        #expect(asked.withLock { $0.count } == before)

        ControlMasterManager.closeAll(in: dir.path)
    }
}

@discardableResult
private func run(_ executable: String, _ arguments: [String], environment: [String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment {
        process.environment = Dictionary(uniqueKeysWithValues: environment.compactMap { pair -> (String, String)? in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
        })
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(executable) failed: \(text)"])
    }
    return text
}
