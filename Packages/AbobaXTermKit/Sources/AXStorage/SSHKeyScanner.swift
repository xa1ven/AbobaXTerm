import Foundation

/// A private key found in ~/.ssh.
public struct SSHKeyInfo: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Key type from the matching .pub file, e.g. "ssh-ed25519".
    public let type: String?
    public let comment: String?

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// Finds private keys in a directory (normally ~/.ssh).
public enum SSHKeyScanner {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    private static let ignoredNames: Set<String> = [
        "config", "known_hosts", "known_hosts.old", "authorized_keys", "authorized_keys2", "environment",
    ]

    public static func scan(directory: URL = defaultDirectory) -> [SSHKeyInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var keys: [SSHKeyInfo] = []
        for name in names.sorted() {
            if name.hasPrefix(".") || name.hasSuffix(".pub") || ignoredNames.contains(name) { continue }
            let url = directory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard looksLikePrivateKey(url) else { continue }

            var type: String?
            var comment: String?
            if let pub = try? String(contentsOf: url.appendingPathExtension("pub"), encoding: .utf8) {
                let parts = pub.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                type = parts.first.map(String.init)
                if parts.count > 2 { comment = parts[2].trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            keys.append(SSHKeyInfo(path: url.path, type: type, comment: comment))
        }
        return keys
    }

    /// Reads only the first bytes and checks for a PEM/OpenSSH private key header.
    static func looksLikePrivateKey(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64),
              let head = String(data: data, encoding: .utf8) else { return false }
        return head.hasPrefix("-----BEGIN") && head.contains("PRIVATE KEY")
    }
}
