import AXModels
import Foundation

/// Builds the argv for the system `ssh` binary from a `Session`.
public struct SSHCommandBuilder: Sendable {
    public enum BuildError: Error, Equatable, LocalizedError {
        case emptyHost
        case invalidHost(String)
        case invalidPort(Int)
        case invalidJumpHost(String)
        case invalidKeyPath
        case invalidExtraOptions(String)

        public var errorDescription: String? {
            switch self {
            case .emptyHost: "Host is empty"
            case .invalidHost(let h): "Invalid host: \(h)"
            case .invalidPort(let p): "Invalid port: \(p)"
            case .invalidJumpHost(let j): "Invalid jump host: \(j)"
            case .invalidKeyPath: "Key file is not set"
            case .invalidExtraOptions(let reason): "Extra options: \(reason)"
            }
        }
    }

    public var sshPath: String
    /// Directory for ControlMaster sockets (must be short, see AppPaths).
    public var controlDirectory: String
    /// How long the master connection stays alive after the last client exits.
    public var controlPersistSeconds: Int
    /// Program ssh runs as `xauth list <display>` to learn the X server's
    /// cookie. The app points it at a stand-in written by its built-in X
    /// server (macOS has no xauth of its own).
    public var xauthPath: String?

    public init(sshPath: String = "/usr/bin/ssh", controlDirectory: String, controlPersistSeconds: Int = 600,
                xauthPath: String? = nil) {
        self.sshPath = sshPath
        self.controlDirectory = controlDirectory
        self.controlPersistSeconds = controlPersistSeconds
        self.xauthPath = xauthPath
    }

    public static let controlSocketPrefix = "cm-"

    /// Per-session ControlPath; `%C` is ssh's hash of local host, remote
    /// host, port, user and jump host. X11 sessions get their own master:
    /// the master forwards X11 to the DISPLAY it was started with, so a
    /// master opened without X11 must not be reused once it is turned on.
    public func controlPath(for session: Session) -> String {
        "\(controlDirectory)/\(Self.controlSocketName(for: session))\(session.x11Forwarding ? "x-" : "")%C"
    }

    /// File-name prefix of this session's master sockets, e.g. "cm-abcdef01-".
    public static func controlSocketName(for session: Session) -> String {
        "\(controlSocketPrefix)\(session.id.uuidString.prefix(8).lowercased())-"
    }

    /// Arguments without argv[0]; the destination host is always last, after `--`.
    public func arguments(for session: Session) throws -> [String] {
        let host = session.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw BuildError.emptyHost }
        guard Self.isSafeToken(host) else { throw BuildError.invalidHost(host) }

        var args: [String] = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath(for: session))",
            "-o", "ControlPersist=\(controlPersistSeconds)",
        ]

        if let port = session.port {
            guard (1...65535).contains(port) else { throw BuildError.invalidPort(port) }
            args += ["-p", String(port)]
        }
        if let user = session.user?.trimmingCharacters(in: .whitespaces), !user.isEmpty {
            guard Self.isSafeToken(user) else { throw BuildError.invalidHost(user) }
            args += ["-l", user]
        }

        switch session.auth {
        case .system:
            break
        case .publicKey(let path):
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw BuildError.invalidKeyPath }
            args += ["-i", (trimmed as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        case .password:
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }

        if let jump = session.jumpHost?.trimmingCharacters(in: .whitespaces), !jump.isEmpty {
            guard Self.isSafeToken(jump) else { throw BuildError.invalidJumpHost(jump) }
            args += ["-J", jump]
        }

        if session.x11Forwarding {
            args.append("-Y")
            if let xauthPath { args += ["-o", "XAuthLocation=\(xauthPath)"] }
        }

        do {
            args += try ShellWords.split(session.extraOptions)
        } catch {
            throw BuildError.invalidExtraOptions(error.localizedDescription)
        }

        args += ["--", host]
        return args
    }

    /// Arguments for an extra channel over the session's existing master
    /// (`ControlMaster=no`, no X11, no tty, never prompts): either a
    /// subsystem such as "sftp" or a remote command.
    public func muxArguments(for session: Session, subsystem: String? = nil, command: [String] = []) throws -> [String] {
        // Same ControlPath as the terminal (it depends on the X11 flag), but no -Y.
        var args = try arguments(for: session).filter { $0 != "-Y" }
        if let i = args.firstIndex(of: "ControlMaster=auto") { args[i] = "ControlMaster=no" }
        guard let dashes = args.lastIndex(of: "--") else { return args }
        var options = ["-T", "-x", "-o", "BatchMode=yes"]
        if subsystem != nil { options.append("-s") }
        args.insert(contentsOf: options, at: dashes)
        if let subsystem { args.append(subsystem) }
        return args + command
    }

    /// `ssh -O check` arguments: exit status 0 when the master is up.
    /// Host, port, user and jump host must match: they feed `%C`.
    public func checkArguments(for session: Session) throws -> [String] {
        ["-O", "check"] + (try arguments(for: session).filter { $0 != "-Y" })
    }

    /// Copy-pasteable command line for display and debugging.
    public func commandLine(for session: Session) -> String {
        guard let args = try? arguments(for: session) else { return "" }
        return ShellWords.join(["ssh"] + args)
    }

    /// No whitespace/control characters and no leading dash (option injection).
    static func isSafeToken(_ value: String) -> Bool {
        !value.hasPrefix("-") && !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
}
