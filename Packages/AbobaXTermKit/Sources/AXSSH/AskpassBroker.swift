import AXAskpassProtocol
import AXStorage
import Foundation
import Synchronization

/// Who is asking: registered for each ssh process the app launches.
public struct AskpassContext: Sendable {
    public var sessionID: UUID
    public var sessionName: String
    /// Host names that count as "the session's host" for password autofill
    /// (the configured host and the HostName resolved by `ssh -G`).
    public var hostCandidates: [String]
    public var user: String?
    public var hasJumpHost: Bool
    /// False for ad-hoc quick-connect sessions that are not saved.
    public var canSavePassword: Bool

    public init(sessionID: UUID, sessionName: String, hostCandidates: [String], user: String?,
                hasJumpHost: Bool, canSavePassword: Bool) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.hostCandidates = hostCandidates
        self.user = user
        self.hasJumpHost = hasJumpHost
        self.canSavePassword = canSavePassword
    }
}

/// A question shown to the user.
public struct AskpassQuestion: Sendable {
    public var kind: AskpassPromptKind
    public var prompt: String
    public var sessionName: String
    /// Whether to offer "Save in Keychain".
    public var offerSave: Bool
    /// True when a saved secret was already tried and rejected.
    public var isRetry: Bool
}

public struct AskpassAnswer: Sendable {
    public var value: String
    public var save: Bool

    public init(value: String, save: Bool) {
        self.value = value
        self.save = save
    }
}

/// Answers SSH_ASKPASS requests coming from `abx-askpass`.
///
/// Saved passwords and key passphrases are filled in from the Keychain on
/// the first prompt; anything else (or a retry after a wrong password) is
/// shown to the user via `present`.
public final class AskpassBroker: Sendable {
    public typealias Presenter = @Sendable (AskpassQuestion) async -> AskpassAnswer?

    private struct Registration {
        var context: AskpassContext
        var triedSavedPassword = false
        var triedSavedPassphrases: Set<String> = []
    }

    public let socketPath: String
    private let keychain: KeychainStore
    private let present: Presenter
    private let registrations = Mutex<[String: Registration]>([:])
    private let server = Mutex<UnixSocketServer?>(nil)

    public init(socketPath: String, keychain: KeychainStore, present: @escaping Presenter) throws {
        self.socketPath = socketPath
        self.keychain = keychain
        self.present = present
        let server = try UnixSocketServer(path: socketPath) { [weak self] data in
            guard let self else { return (try? AskpassCodec.encodeLine(AskpassResponse(answer: nil))) ?? Data() }
            let response: AskpassResponse
            if let request = try? AskpassCodec.decodeLine(AskpassRequest.self, from: data) {
                response = await self.handle(request)
            } else {
                response = AskpassResponse(answer: nil)
            }
            return (try? AskpassCodec.encodeLine(response)) ?? Data()
        }
        self.server.withLock { $0 = server }
    }

    public func stop() {
        server.withLock { server in
            server?.stop()
            server = nil
        }
    }

    /// Registers an ssh launch and returns the token to put into its environment.
    public func register(_ context: AskpassContext) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
        registrations.withLock { $0[token] = Registration(context: context) }
        return token
    }

    public func unregister(_ token: String) {
        _ = registrations.withLock { $0.removeValue(forKey: token) }
    }

    func handle(_ request: AskpassRequest) async -> AskpassResponse {
        guard let registration = registrations.withLock({ $0[request.token] }) else {
            return AskpassResponse(answer: nil)
        }
        let context = registration.context
        let kind = AskpassPrompt.classify(request.prompt, hint: request.hint)

        func ask(offerSave: Bool, isRetry: Bool = false) async -> AskpassAnswer? {
            await present(AskpassQuestion(kind: kind, prompt: request.prompt, sessionName: context.sessionName,
                                          offerSave: offerSave, isRetry: isRetry))
        }

        switch kind {
        case .password:
            let account = KeychainStore.sessionAccount(context.sessionID)
            let mayAutofill = AskpassPrompt.shouldAutofillPassword(
                prompt: request.prompt, hostCandidates: context.hostCandidates,
                user: context.user, hasJumpHost: context.hasJumpHost)
            if mayAutofill, !registration.triedSavedPassword {
                markTried(token: request.token) { $0.triedSavedPassword = true }
                if let saved = try? keychain.password(account: account) {
                    return AskpassResponse(answer: saved)
                }
            }
            let retry = mayAutofill && registration.triedSavedPassword
            guard let answer = await ask(offerSave: context.canSavePassword && mayAutofill, isRetry: retry) else {
                return AskpassResponse(answer: nil)
            }
            if answer.save {
                try? keychain.setPassword(answer.value, account: account, label: "AbobaXTerm: \(context.sessionName)")
            }
            return AskpassResponse(answer: answer.value)

        case .passphrase(let keyPath):
            guard let keyPath else {
                return AskpassResponse(answer: await ask(offerSave: false)?.value)
            }
            let account = KeychainStore.keyAccount(keyPath)
            let alreadyTried = registration.triedSavedPassphrases.contains(keyPath)
            if !alreadyTried {
                markTried(token: request.token) { $0.triedSavedPassphrases.insert(keyPath) }
                if let saved = try? keychain.password(account: account) {
                    return AskpassResponse(answer: saved)
                }
            }
            guard let answer = await ask(offerSave: true, isRetry: alreadyTried) else {
                return AskpassResponse(answer: nil)
            }
            if answer.save {
                try? keychain.setPassword(answer.value, account: account, label: "AbobaXTerm: key \(keyPath)")
            }
            return AskpassResponse(answer: answer.value)

        case .hostKeyConfirmation:
            let accepted = await ask(offerSave: false) != nil
            return AskpassResponse(answer: accepted ? "yes" : "no")

        case .confirm:
            return AskpassResponse(answer: await ask(offerSave: false) != nil ? "" : nil)

        case .notice:
            _ = await ask(offerSave: false)
            return AskpassResponse(answer: "")

        case .other:
            return AskpassResponse(answer: await ask(offerSave: false)?.value)
        }
    }

    private func markTried(token: String, _ update: (inout Registration) -> Void) {
        registrations.withLock { regs in
            if var reg = regs[token] {
                update(&reg)
                regs[token] = reg
            }
        }
    }
}
