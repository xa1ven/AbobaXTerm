import AXAskpassProtocol
import AXModels
import AXL10n
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
    /// Things to tell the user in the terminal before ssh starts (e.g. X11 problems).
    public var notices: [String] = []
    /// Session summary to show in the terminal; nil when it is turned off.
    public var banner: SessionBanner?
    /// When to show it.
    public var bannerTiming = BannerTiming.beforeConnecting
    /// Temporary file ssh prints once it has signed in; removed by `finish`.
    public var bannerFile: String?
}

public enum BannerTiming: Sendable {
    /// ssh itself prints it right after authentication (`LocalCommand`).
    case afterAuthentication
    /// The app prints it before ssh starts: a tab that joins an open master
    /// connection runs no `LocalCommand`, and the user's own one is not replaced.
    case beforeConnecting
}

/// What the session summary says about the app.
public struct BannerOptions: Sendable {
    public var appVersion: String
    public var monitoring: Bool

    public init(appVersion: String, monitoring: Bool) {
        self.appVersion = appVersion
        self.monitoring = monitoring
    }
}

/// Turns a session into an `SSHLaunchSpec`: builds arguments, resolves the
/// effective host with `ssh -G`, registers with the askpass broker and
/// prepares the environment.
public struct SSHLauncher: Sendable {
    public let builder: SSHCommandBuilder
    public let broker: AskpassBroker?
    /// Path of `abx-askpass`; nil disables askpass (ssh then prompts in the terminal).
    public let askpassHelperPath: String?
    /// Local X display for sessions with X11 forwarding; nil when there is none.
    public let x11: (any X11DisplayProviding)?
    /// nil: no session summary in the terminal.
    public let banner: BannerOptions?

    public init(builder: SSHCommandBuilder, broker: AskpassBroker?, askpassHelperPath: String?,
                x11: (any X11DisplayProviding)? = nil, banner: BannerOptions? = nil) {
        self.banner = banner
        self.builder = builder
        self.broker = broker
        self.askpassHelperPath = askpassHelperPath
        self.x11 = x11
    }

    public func prepare(_ session: Session, isSaved: Bool) async throws -> SSHLaunchSpec {
        let arguments = try builder.arguments(for: session)
        var token: String?
        let needsResolved = (broker != nil && askpassHelperPath != nil) || banner != nil
        let resolved = needsResolved ? await SSHConfigResolver.resolve(sshPath: builder.sshPath, arguments: arguments) : nil

        if let broker, askpassHelperPath != nil {
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

        var extra: [String: String] = [:]
        var notices: [String] = []
        if session.x11Forwarding {
            do {
                guard let x11 else { throw X11Unavailable() }
                extra["DISPLAY"] = try await x11.prepareDisplay()
            } catch {
                notices.append("X11: \(error.localizedDescription) " + L("Windows from the server will not open."))
            }
        }

        var summary: SessionBanner?
        var timing = BannerTiming.beforeConnecting
        if let banner {
            let shared = await ControlMasterManager.isMasterRunning(session, builder: builder)
            var context = SessionBanner.Context(appVersion: banner.appVersion, resolved: resolved)
            context.isShared = shared
            context.x11Ready = session.x11Forwarding ? extra["DISPLAY"] != nil : nil
            context.monitoring = banner.monitoring
            context.isSaved = isSaved
            if case .publicKey(let path) = session.auth {
                let file = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath + ".pub"
                context.keyComment = (try? String(contentsOfFile: file, encoding: .utf8))
                    .flatMap(SessionBanner.keyComment(publicKeyFile:))
            }
            summary = SessionBanner(session: session, context: context)
            // ssh -G returns nil when it fails; then nothing is known about a LocalCommand of the user.
            if !shared, let resolved, resolved.localCommand == nil { timing = .afterAuthentication }
        }

        return SSHLaunchSpec(
            executable: builder.sshPath,
            arguments: arguments,
            environment: environment(token: token, extra: extra),
            askpassToken: token,
            commandLine: ShellWords.join(["ssh"] + arguments),
            notices: notices,
            banner: summary,
            bannerTiming: timing
        )
    }

    /// Makes ssh print `text` as soon as it has signed in, before anything
    /// the server says: the text goes to a private file that `LocalCommand` cats.
    public func installBanner(_ text: String, in spec: inout SSHLaunchSpec) throws {
        let path = "\(builder.controlDirectory)/banner-\(UUID().uuidString.prefix(8).lowercased()).txt"
        guard let dashes = spec.arguments.lastIndex(of: "--"),
              FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        spec.bannerFile = path
        spec.arguments.insert(contentsOf: [
            "-o", "PermitLocalCommand=yes",
            // "%" starts a token in LocalCommand.
            "-o", "LocalCommand=/bin/cat \(ShellWords.join([path]).replacingOccurrences(of: "%", with: "%%"))",
        ], at: dashes)
    }

    public func finish(_ spec: SSHLaunchSpec) {
        if let token = spec.askpassToken { broker?.unregister(token) }
        if let file = spec.bannerFile { try? FileManager.default.removeItem(atPath: file) }
    }

    private struct X11Unavailable: LocalizedError {
        var errorDescription: String? { L("No X server is available.") }
    }

    func environment(token: String?, extra: [String: String] = [:]) -> [String] {
        var extra = extra
        if let token, let helper = askpassHelperPath, let broker {
            extra["SSH_ASKPASS"] = helper
            extra["SSH_ASKPASS_REQUIRE"] = "force"
            extra[AskpassEnvironment.socketPath] = broker.socketPath
            extra[AskpassEnvironment.token] = token
        }
        return TerminalEnvironment.make(extra: extra)
    }
}
