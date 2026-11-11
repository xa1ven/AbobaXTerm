@testable import AXSFTP
import Foundation
import Testing

/// Opt-in: runs against a throwaway local sshd (never a real server).
///   ABX_E2E_SFTP_PORT=2222 ABX_E2E_SFTP_KEY=/path/client_key \
///   ABX_E2E_SFTP_KNOWN_HOSTS=/path/kh ABX_E2E_SFTP_DIR=/path/writable-dir \
///   swift test --filter SFTPIntegration
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ABX_E2E_SFTP_PORT"] != nil), .serialized)
struct SFTPIntegrationTests {
    let env = ProcessInfo.processInfo.environment

    func connect() async throws -> SFTPClient {
        let args = [
            "-F", "/dev/null", "-p", env["ABX_E2E_SFTP_PORT"]!,
            "-i", env["ABX_E2E_SFTP_KEY"]!, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "UserKnownHostsFile=\(env["ABX_E2E_SFTP_KNOWN_HOSTS"]!)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-T", "-x", "-s", "--", "127.0.0.1", "sftp",
        ]
        return try await SFTPClient.connect(executable: "/usr/bin/ssh", arguments: args)
    }

    func makeRoot() throws -> String {
        let root = env["ABX_E2E_SFTP_DIR"]! + "/sftp-test-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test func browseAndModify() async throws {
        let client = try await connect()
        defer { client.close() }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        #expect(try await client.realPath(root + "/.") == root)
        try await client.makeDirectory(root + "/b-dir")
        try await client.createFile(root + "/a.txt")
        try "x".write(toFile: root + "/b-dir/inner", atomically: true, encoding: .utf8)
        symlink(root + "/b-dir", root + "/link")

        let items = try await client.list(root)
        #expect(items.map(\.name) == ["b-dir", "link", "a.txt"])
        #expect(items[1].isSymlink && items[1].isDirectory)

        try await client.rename(root + "/a.txt", to: root + "/c.txt")
        #expect(try await client.exists(root + "/c.txt"))
        #expect(try await !client.exists(root + "/a.txt"))

        await #expect(throws: SFTPError.self) { try await client.createFile(root + "/c.txt") }

        try await client.removeRecursively(root + "/b-dir")
        #expect(!FileManager.default.fileExists(atPath: root + "/b-dir"))

        let missing = await #expect(throws: SFTPError.self) { try await client.list(root + "/nope") }
        #expect(missing?.status == .noSuchFile)
    }

    @Test func transfersAndEditorIO() async throws {
        let client = try await connect()
        defer { client.close() }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // ~5 MB with an odd size to exercise pipelining and the last chunk.
        var bytes = [UInt8](repeating: 0, count: 5 * 1024 * 1024 + 777)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) }
        let local = URL(fileURLWithPath: root + "/local.bin")
        try Data(bytes).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: local.path)

        let reported = LockedValue<UInt64>(0)
        try await client.upload(local, to: root + "/remote.bin") { reported.set($0) }
        #expect(reported.get() == UInt64(bytes.count))
        #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/remote.bin")) == Data(bytes))
        #expect(try await client.attributes(root + "/remote.bin").permissions! & 0o777 == 0o750)

        let back = URL(fileURLWithPath: root + "/back.bin")
        try await client.download(root + "/remote.bin", to: back) { _ in }
        #expect(try Data(contentsOf: back) == Data(bytes))

        try await client.writeFile(root + "/note.txt", data: Data("hello\n".utf8))
        let (text, attrs) = try await client.readFile(root + "/note.txt")
        #expect(String(decoding: text, as: UTF8.self) == "hello\n")
        #expect(attrs.size == 6)

        // Empty file round trip.
        try await client.writeFile(root + "/empty", data: Data())
        #expect(try await client.readFile(root + "/empty").0.isEmpty)
    }

    @Test func cancelledDownloadRemovesPartialFile() async throws {
        let client = try await connect()
        defer { client.close() }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data(count: 20 * 1024 * 1024).write(to: URL(fileURLWithPath: root + "/big"))

        let target = URL(fileURLWithPath: root + "/big.copy")
        let task = Task {
            try await client.download(root + "/big", to: target) { done in
                if done > 1024 * 1024 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // The connection is still usable afterwards.
        #expect(try await client.exists(root + "/big"))
    }

    @Test func folderRoundTrip() async throws {
        let client = try await connect()
        defer { client.close() }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/src/sub/deeper", withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: URL(fileURLWithPath: root + "/src/a.bin"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/src/sub/deeper/b.txt"))

        let up = LockedValue<UInt64>(0)
        try await client.uploadItem(URL(fileURLWithPath: root + "/src"), to: root + "/up") { up.set($0) }
        #expect(up.get() == 100_001)
        #expect(fm.fileExists(atPath: root + "/up/sub/deeper/b.txt"))
        #expect(try await client.totalSize(of: root + "/up") == 100_001)

        let down = URL(fileURLWithPath: root + "/down")
        try await client.downloadItem(root + "/up", to: down) { _ in }
        #expect(try Data(contentsOf: down.appendingPathComponent("a.bin")).count == 100_000)
        #expect(try String(contentsOf: down.appendingPathComponent("sub/deeper/b.txt"), encoding: .utf8) == "x")
    }

    @Test func deadConnectionFailsFast() async throws {
        let client = try await connect()
        client.close()
        await #expect(throws: SFTPError.self) { try await client.list("/") }
    }
}

final class LockedValue<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}
