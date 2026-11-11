import AXAskpassProtocol
import AXModels
import Foundation

/// Everything needed to start ssh in a PTY.
public struct SSHLaunchSpec: Sendable {
    public var executable: String
    /// Arguments without argv[0].
    public var arguments: [String]
    /// "KEY=value" strings.
    public var environment: [String]
    /// Askpass registration; pass to `SSHLauncher.finish(_:)` when ssh exits.
    public var askpassToken: String?
    public var commandLine: String
}

/// Turns a session into an `SSHLaunchSpec`: builds arguments, resolves the
/// effective host with `ssh -G`, registers with the askpass broker and
/// prepares the environment.
public struct SSHLauncher: Sendable {
    public let builder: SSHCommandBuilder
    public let broker: AskpassBroker?
    /// Path of `abx-askpass`; nil disables askpass (ssh then prompts in the terminal).
    public let askpassHelperPath: String?

    public init(builder: SSHCommandBuilder, broker: AskpassBroker?, askpassHelperPath: String?) {
        self.builder = builder
        self.broker = broker
        self.askpassHelperPath = askpassHelperPath
    }

    public func prepare(_ session: Session, isSaved: Bool) async throws -> SSHLaunchSpec {
        let arguments = try builder.arguments(for: session)
        var token: String?

        if let broker, askpassHelperPath != nil {
            let resolved = await SSHConfigResolver.resolve(sshPath: builder.sshPath, arguments: arguments)
            let candidates = [session.host, resolved?.hostName].compactMap { $0 }
            let jump = session.jumpHost?.isEmpty == false ? session.jumpHost : resolved?.proxyJump
            token = broker.register(AskpassContext(
                sessionID: session.id,
                sessionName: session.displayName,
                hostCandidates: candidates,
                user: resolved?.user ?? session.user,
                hasJumpHost: jump != nil,
                canSavePassword: isSaved
            ))
        }

        return SSHLaunchSpec(
            executable: builder.sshPath,
            arguments: arguments,
            environment: environment(token: token),
            askpassToken: token,
            commandLine: ShellWords.join(["ssh"] + arguments)
        )
    }

    public func finish(_ spec: SSHLaunchSpec) {
        if let token = spec.askpassToken { broker?.unregister(token) }
    }

    func environment(token: String?) -> [String] {
        var extra: [String: String] = [:]
        if let token, let helper = askpassHelperPath, let broker {
            extra["SSH_ASKPASS"] = helper
            extra["SSH_ASKPASS_REQUIRE"] = "force"
            extra[AskpassEnvironment.socketPath] = broker.socketPath
            extra[AskpassEnvironment.token] = token
        }
        return TerminalEnvironment.make(extra: extra)
    }
}
