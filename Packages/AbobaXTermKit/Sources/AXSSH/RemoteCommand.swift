import AXModels
import Foundation

/// Runs a command on the server over the session's existing master connection.
public enum RemoteCommand {
    public struct Result: Sendable {
        public var output: Data
        public var status: Int32
    }

    /// `command` is passed to the remote shell as is; quote arguments with `ShellWords.quote`.
    /// Cancelling the task terminates the local ssh process.
    public static func run(_ command: String, session: Session, builder: SSHCommandBuilder) async throws -> Result {
        let args = try builder.muxArguments(for: session, command: [command])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: builder.sshPath)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Read on a background thread so a large output cannot fill the pipe.
                let reader = Thread {
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: Result(output: data, status: process.terminationStatus))
                    }
                }
                do {
                    try process.run()
                    reader.start()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
