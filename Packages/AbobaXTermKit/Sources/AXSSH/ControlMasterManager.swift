import AXModels
import Foundation

/// Housekeeping for ControlMaster sockets created by the app.
public enum ControlMasterManager {
    /// Sends `ssh -O exit` to master sockets in `directory`; when
    /// `socketPrefixes` is given, only to sockets whose name starts with one of them.
    /// Called on app quit; runs synchronously with a short timeout per socket.
    public static func closeAll(in directory: String, socketPrefixes: Set<String>? = nil, sshPath: String = "/usr/bin/ssh") {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasPrefix(SSHCommandBuilder.controlSocketPrefix) {
            if let socketPrefixes, !socketPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sshPath)
            // The host argument is required but unused when -S is a literal path.
            process.arguments = ["-S", path, "-O", "exit", "abx-master"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning { process.terminate() }
        }
    }
}

extension ControlMasterManager {
    /// Whether the session's master connection is up (`ssh -O check`).
    public static func isMasterRunning(_ session: Session, builder: SSHCommandBuilder) async -> Bool {
        guard let args = try? builder.checkArguments(for: session) else { return false }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: builder.sshPath)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
