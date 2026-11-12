import AXL10n
import AppKit
import AXModels
import AXSSH
import Observation

/// One terminal tab: ssh or a local login shell running in a PTY inside a SwiftTerm view.
@MainActor
@Observable
public final class TerminalTab: Identifiable {
    public enum Target: Sendable {
        case ssh(Session, isSaved: Bool)
        case local
    }

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case running
        case exited(code: Int32?)
        case failed(String)

        public var isActive: Bool { self == .connecting || self == .running }
    }

    public let id = UUID()
    public private(set) var target: Target
    public private(set) var state: State = .idle
    /// Title set by the remote side / shell via OSC escape sequences.
    public private(set) var remoteTitle: String?
    /// Directory reported via OSC 7 (local shells that support it).
    public private(set) var currentDirectory: String?
    public private(set) var commandLine: String = ""

    @ObservationIgnored public let terminalView: AXTerminalView
    @ObservationIgnored private let launcher: SSHLauncher
    @ObservationIgnored private var spec: SSHLaunchSpec?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    /// Called once ssh has been started (used to update "last connected").
    @ObservationIgnored public var onLaunched: ((Session) -> Void)?

    public init(target: Target, launcher: SSHLauncher) {
        self.target = target
        self.launcher = launcher
        self.terminalView = AXTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminalView.processDelegate = self
    }

    // MARK: Descriptors

    public var session: Session? {
        if case .ssh(let session, _) = target { session } else { nil }
    }

    public var isLocal: Bool {
        if case .local = target { true } else { false }
    }

    public var isSaved: Bool {
        if case .ssh(_, let saved) = target { saved } else { false }
    }

    public var title: String {
        session?.displayName ?? L("Local Terminal")
    }

    public var subtitle: String {
        if let session { return session.target }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let dir = currentDirectory else { return "~" }
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }

    /// Updates the session used for the next (re)connect, e.g. after editing.
    public func updateSession(_ updated: Session) {
        guard case .ssh(let current, let saved) = target, current.id == updated.id else { return }
        target = .ssh(updated, isSaved: saved)
    }

    // MARK: Lifecycle

    public func connect() {
        guard !state.isActive else { return }
        remoteTitle = nil
        switch target {
        case .local:
            startLocalShell()
        case .ssh(let session, let isSaved):
            startSSH(session, isSaved: isSaved)
        }
    }

    private func startLocalShell() {
        let shell = TerminalEnvironment.userShell
        let name = (shell as NSString).lastPathComponent
        commandLine = shell
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: TerminalEnvironment.make(),
            execName: "-" + name, // leading dash = login shell
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        state = .running
    }

    private func startSSH(_ session: Session, isSaved: Bool) {
        state = .connecting
        terminalView.feed(text: "\u{1B}[2m" + L("Connecting to %@…", session.target) + "\u{1B}[0m\r\n")

        launchTask = Task { [weak self, launcher] in
            do {
                let spec = try await launcher.prepare(session, isSaved: isSaved)
                guard let self, self.state == .connecting else {
                    launcher.finish(spec)
                    return
                }
                self.spec = spec
                self.commandLine = spec.commandLine
                for notice in spec.notices {
                    self.terminalView.feed(text: "\u{1B}[33m\(notice)\u{1B}[0m\r\n")
                }
                self.terminalView.startProcess(
                    executable: spec.executable,
                    args: spec.arguments,
                    environment: spec.environment,
                    execName: "ssh")
                self.state = .running
                self.onLaunched?(session)
            } catch {
                guard let self else { return }
                self.state = .failed(error.localizedDescription)
                self.terminalView.feed(text: "\u{1B}[31m\(error.localizedDescription)\u{1B}[0m\r\n")
            }
        }
    }

    public func reconnect() {
        guard !state.isActive else { return }
        terminalView.feed(text: "\r\n")
        connect()
    }

    /// Terminates the process (if running) and releases the askpass registration.
    public func close() {
        launchTask?.cancel()
        if state == .running {
            terminalView.terminate()
        }
        if let spec { launcher.finish(spec) }
        spec = nil
        state = .exited(code: nil)
    }
}

extension TerminalTab: AXTerminalViewDelegate {
    public func terminalTitleChanged(_ title: String) {
        remoteTitle = title.isEmpty ? nil : title
    }

    public func terminalDirectoryChanged(_ directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else {
            currentDirectory = directory
            return
        }
        currentDirectory = url.path
    }

    public func terminalProcessTerminated(exitCode: Int32?) {
        if let spec { launcher.finish(spec) }
        spec = nil
        guard state == .running else { return }
        state = .exited(code: exitCode)
        let code = exitCode.map(String.init) ?? L("signal")
        let text = isLocal ? L("Shell exited, exit code %@. Press ⌘R to restart.", code)
                           : L("Connection closed, exit code %@. Press ⌘R to reconnect.", code)
        terminalView.feed(text: "\r\n\u{1B}[2m[\(text)]\u{1B}[0m\r\n")
    }

    public func terminalProcessFailedToStart(_ message: String) {
        if let spec { launcher.finish(spec) }
        spec = nil
        state = .failed(message)
    }
}
