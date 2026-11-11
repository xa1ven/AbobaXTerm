import Foundation

/// Folder transfers: one progress value (bytes) for the whole tree.
extension SFTPClient {
    /// Total size of a remote file or directory tree (symlinks are not followed).
    public func totalSize(of path: String) async throws -> UInt64 {
        let attrs = try await attributes(path, followLinks: false)
        guard attrs.isDirectory else { return attrs.size ?? 0 }
        var total: UInt64 = 0
        for entry in try await list(path) {
            try Task.checkCancellation()
            total += entry.attributes.isDirectory ? try await totalSize(of: entry.path) : entry.size
        }
        return total
    }

    /// Total size of a local file or directory tree.
    public static func localSize(of url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return UInt64(values.fileSize ?? 0) }
        var total: UInt64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let child = enumerator?.nextObject() as? URL {
            if let v = try? child.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += UInt64(v.fileSize ?? 0)
            }
        }
        return total
    }

    /// Uploads a local file or folder to `remotePath` (files are overwritten,
    /// existing folders are merged).
    public func uploadItem(_ localURL: URL, to remotePath: String, progress: @escaping SFTPProgress) async throws {
        let base = Counter()
        try await uploadItem(localURL, to: remotePath, base: base, progress: progress)
    }

    private func uploadItem(_ localURL: URL, to remotePath: String, base: Counter, progress: @escaping SFTPProgress) async throws {
        try Task.checkCancellation()
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            // Upload what the link points to only if it is a regular file.
            let resolved = localURL.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return }
        }
        if values.isDirectory == true {
            if !(try await exists(remotePath)) {
                try await makeDirectory(remotePath)
            }
            let children = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try await uploadItem(child, to: Self.join(remotePath, child.lastPathComponent), base: base, progress: progress)
            }
        } else {
            let start = base.value
            try await upload(localURL, to: remotePath) { progress(start + $0) }
            base.value = start + SFTPClient.localSize(of: localURL)
            progress(base.value)
        }
    }

    /// Downloads a remote file or folder to `localURL` (must not exist).
    public func downloadItem(_ remotePath: String, to localURL: URL, progress: @escaping SFTPProgress) async throws {
        let base = Counter()
        do {
            try await downloadItem(remotePath, to: localURL, base: base, progress: progress)
        } catch {
            // Do not leave half a folder behind.
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    private func downloadItem(_ remotePath: String, to localURL: URL, base: Counter, progress: @escaping SFTPProgress) async throws {
        try Task.checkCancellation()
        let attrs = try await attributes(remotePath, followLinks: true)
        if attrs.isDirectory {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false)
            for entry in try await list(remotePath) {
                // Symlinks to directories are skipped to avoid loops.
                if entry.isSymlink && entry.isDirectory { continue }
                try await downloadItem(entry.path, to: localURL.appendingPathComponent(entry.name), base: base, progress: progress)
            }
        } else if attrs.isRegularFile {
            let start = base.value
            try await download(remotePath, to: localURL) { progress(start + $0) }
            base.value = start + (attrs.size ?? 0)
            progress(base.value)
        }
        // Devices, sockets and FIFOs are skipped.
    }
}

/// Running byte count shared by the recursive helpers (used sequentially).
private final class Counter: @unchecked Sendable {
    var value: UInt64 = 0
}
