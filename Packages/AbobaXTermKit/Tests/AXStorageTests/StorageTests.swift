import AXModels
@testable import AXStorage
import Foundation
import Testing

@Suite struct SessionRepositoryTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-tests-\(UUID().uuidString)")

    @Test func missingFileGivesEmptyLibrary() throws {
        let repo = SessionRepository(fileURL: dir.appendingPathComponent("sessions.json"))
        let lib = try repo.load()
        #expect(lib.sessions.isEmpty)
        #expect(lib.folders.isEmpty)
    }

    @Test func saveLoadRoundTripAndBackup() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sessions.json")
        let repo = SessionRepository(fileURL: file)
        let folder = Folder(name: "F")
        var lib = SessionLibrary(folders: [folder], sessions: [Session(name: "x", host: "h", folderID: folder.id,
                                                                            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125))])
        try repo.save(lib)
        #expect(try repo.load() == lib)

        lib.upsert(Session(name: "y", host: "h2"))
        try repo.save(lib)
        #expect(try repo.load().sessions.count == 2)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))

        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(!json.contains("password"))
        #expect(json.contains("2023-11-14T22:13:20.125Z"))
    }

    @Test func corruptedFileIsPreserved() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sessions.json")
        try Data("{ not json".utf8).write(to: file)
        let repo = SessionRepository(fileURL: file)
        do {
            _ = try repo.load()
            Issue.record("expected an error")
        } catch let SessionRepository.LoadError.corrupted(backupURL, _) {
            #expect(FileManager.default.fileExists(atPath: backupURL.path))
        }
    }
}

@Suite struct SSHKeyScannerTests {
    @Test func findsPrivateKeysOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n"
        try header.write(to: dir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try "ssh-ed25519 AAAA me@mac\n".write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        try "-----BEGIN RSA PRIVATE KEY-----\n".write(to: dir.appendingPathComponent("legacy"), atomically: true, encoding: .utf8)
        try "Host x\n".write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "random".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let keys = SSHKeyScanner.scan(directory: dir)
        #expect(keys.map(\.fileName) == ["id_ed25519", "legacy"])
        #expect(keys[0].type == "ssh-ed25519")
        #expect(keys[0].comment == "me@mac")
        #expect(keys[1].type == nil)
    }
}
