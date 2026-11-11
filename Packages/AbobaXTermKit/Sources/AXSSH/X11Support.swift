import Foundation

/// Finds XQuartz and works out the DISPLAY that ssh -Y should forward to.
public enum X11Support {
    public enum X11Error: Error, LocalizedError, Equatable {
        case notInstalled
        case startFailed

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "XQuartz is not installed (\(X11Support.installCommand))."
            case .startFailed: "XQuartz did not start in time."
            }
        }
    }

    public static let installCommand = "brew install --cask xquartz"
    public static let xauthPath = "/opt/X11/bin/xauth"
    static let xsetPath = "/opt/X11/bin/xset"
    static let appPaths = ["/Applications/Utilities/XQuartz.app", "/Applications/XQuartz.app"]
    static let fallbackSocket = "/tmp/.X11-unix/X0"

    public static var appPath: String? {
        appPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// XQuartz app plus its xauth (ssh needs xauth for the forwarding cookie).
    public static var isInstalled: Bool {
        appPath != nil && FileManager.default.isExecutableFile(atPath: xauthPath)
    }

    /// DISPLAY to give ssh. Prefers the launchd socket XQuartz registers at
    /// login (XQuartz then starts on the first X connection, without an
    /// xterm); otherwise launches XQuartz and uses ":0".
    public static func prepareDisplay(environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> String {
        guard isInstalled else { throw X11Error.notInstalled }

        var display = environment["DISPLAY"].flatMap { $0.isEmpty ? nil : $0 }
        if display == nil {
            display = await run("/bin/launchctl", ["getenv", "DISPLAY"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            if display?.isEmpty == true { display = nil }
        }

        if let display {
            // Wake XQuartz up now so the first window does not wait for it.
            warmUp(display)
            return display
        }

        // No launchd socket (e.g. XQuartz installed but no re-login yet).
        if !FileManager.default.fileExists(atPath: fallbackSocket), let app = appPath {
            _ = await run("/usr/bin/open", ["-g", "-a", app])
            for _ in 0..<60 where !FileManager.default.fileExists(atPath: fallbackSocket) {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard FileManager.default.fileExists(atPath: fallbackSocket) else { throw X11Error.startFailed }
        return ":0"
    }

    static func warmUp(_ display: String) {
        guard FileManager.default.isExecutableFile(atPath: xsetPath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xsetPath)
        process.arguments = ["-display", display, "q"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
    }

    static func run(_ path: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
