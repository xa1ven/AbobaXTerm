import Foundation

/// File system locations used by the app.
public struct AppPaths: Sendable {
    /// ~/Library/Application Support/AbobaXTerm
    public let supportDirectory: URL
    /// Short per-user directory for Unix sockets (ControlMaster, askpass).
    /// Socket paths are limited to 104 bytes, so this cannot live under
    /// "Application Support".
    public let runtimeDirectory: URL

    public init(supportDirectory: URL, runtimeDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.runtimeDirectory = runtimeDirectory
    }

    public static let standard: AppPaths = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(
            supportDirectory: base.appendingPathComponent("AbobaXTerm", isDirectory: true),
            runtimeDirectory: URL(fileURLWithPath: "/tmp/abx-\(getuid())", isDirectory: true)
        )
    }()

    public var sessionsFile: URL {
        supportDirectory.appendingPathComponent("sessions.json")
    }

    /// Creates both directories; the runtime one is forced to mode 0700 and
    /// must be owned by the current user.
    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: runtimeDirectory.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSFilePathErrorKey: runtimeDirectory.path,
                NSLocalizedDescriptionKey: "\(runtimeDirectory.path) is owned by another user",
            ])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory.path)
    }
}
