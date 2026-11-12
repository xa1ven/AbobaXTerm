import AXModels
import Foundation

/// A long-running command on the server, over the session's existing master
/// connection, read line by line.
public enum RemoteStream {
    /// The stream ends when the command exits or the connection closes.
    /// Dropping the stream (or cancelling the task that reads it) terminates
    /// the local ssh process, which closes the channel.
    public static func lines(_ command: String, session: Session, builder: SSHCommandBuilder) throws -> AsyncStream<String> {
        let args = try builder.muxArguments(for: session, command: [command])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: builder.sshPath)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let running = RunningProcess(process)
        let handle = stdout.fileHandleForReading
        return AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            continuation.onTermination = { _ in running.terminate() }
            let reader = Thread {
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        continuation.yield(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                    // A server that never sends a newline must not grow the buffer forever.
                    if pending.count > 1 << 20 { pending.removeAll() }
                }
                running.terminate()
                continuation.finish()
            }
            reader.start()
        }
    }

    private final class RunningProcess: @unchecked Sendable {
        private let process: Process
        init(_ process: Process) { self.process = process }
        /// `Process.terminate()` is safe to call from any thread and after exit.
        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }
}
