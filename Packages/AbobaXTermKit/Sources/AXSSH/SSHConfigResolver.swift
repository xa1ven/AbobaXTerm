import Foundation

/// Effective connection parameters as reported by `ssh -G`
/// (after ~/.ssh/config, Match blocks and command-line options).
public struct ResolvedSSHConfig: Sendable, Equatable {
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var proxyJump: String?

    public init(hostName: String? = nil, user: String? = nil, port: Int? = nil, proxyJump: String? = nil) {
        self.hostName = hostName
        self.user = user
        self.port = port
        self.proxyJump = proxyJump
    }

    /// Parses `ssh -G` output (lowercase "key value" lines).
    public static func parse(_ output: String) -> ResolvedSSHConfig {
        var result = ResolvedSSHConfig()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "hostname": result.hostName = value
            case "user": result.user = value
            case "port": result.port = Int(value)
            case "proxyjump": result.proxyJump = value == "none" ? nil : value
            default: break
            }
        }
        return result
    }
}

public enum SSHConfigResolver {
    /// Runs `ssh -G <arguments>` (no network access) and parses the result.
    public static func resolve(sshPath: String, arguments: [String]) async -> ResolvedSSHConfig? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sshPath)
            process.arguments = ["-G"] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ResolvedSSHConfig.parse(text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
