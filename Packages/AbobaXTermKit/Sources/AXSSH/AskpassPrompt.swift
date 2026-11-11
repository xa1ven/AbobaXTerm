import Foundation

/// What ssh is asking for, derived from the askpass prompt text.
public enum AskpassPromptKind: Equatable, Sendable {
    /// Password or keyboard-interactive password prompt.
    case password
    /// Passphrase for a private key file.
    case passphrase(keyPath: String?)
    /// "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
    case hostKeyConfirmation
    /// SSH_ASKPASS_PROMPT=confirm: only the exit status matters.
    case confirm
    /// SSH_ASKPASS_PROMPT=none: informational, no answer.
    case notice
    /// Anything else (OTP codes, PINs, custom PAM prompts).
    case other
}

public enum AskpassPrompt {
    public static func classify(_ prompt: String, hint: String?) -> AskpassPromptKind {
        switch hint {
        case "confirm": return .confirm
        case "none": return .notice
        default: break
        }
        let lower = prompt.lowercased()
        if lower.contains("(yes/no") || lower.contains("continue connecting") {
            return .hostKeyConfirmation
        }
        if lower.contains("passphrase") {
            return .passphrase(keyPath: keyPath(in: prompt))
        }
        if lower.contains("password") {
            return .password
        }
        return .other
    }

    /// Extracts the key path from "Enter passphrase for key '/path':" or
    /// "Enter passphrase for /path:".
    static func keyPath(in prompt: String) -> String? {
        if let open = prompt.firstIndex(of: "'"),
           let close = prompt[prompt.index(after: open)...].firstIndex(of: "'") {
            return String(prompt[prompt.index(after: open)..<close])
        }
        if let range = prompt.range(of: "passphrase for ", options: .caseInsensitive) {
            var rest = prompt[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("key ") { rest.removeFirst(4) }
            if rest.hasSuffix(":") { rest.removeLast() }
            rest = rest.trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix("/") || rest.hasPrefix("~") ? rest : nil
        }
        return nil
    }

    /// The `user@host` mentioned in a password prompt, if any:
    /// "root@10.0.0.1's password:" or "(root@10.0.0.1) Password:".
    static func mentionedTarget(in prompt: String) -> (user: String?, host: String)? {
        var candidate: Substring?
        if prompt.hasPrefix("("), let close = prompt.firstIndex(of: ")") {
            candidate = prompt[prompt.index(after: prompt.startIndex)..<close]
        } else if let range = prompt.range(of: "'s password", options: .caseInsensitive) {
            candidate = prompt[..<range.lowerBound]
        }
        guard let candidate, !candidate.isEmpty else { return nil }
        if let at = candidate.lastIndex(of: "@") {
            return (String(candidate[..<at]), String(candidate[candidate.index(after: at)...]))
        }
        return (nil, String(candidate))
    }

    /// Whether a saved session password may be sent for this prompt.
    ///
    /// The password is only auto-filled when the prompt clearly targets the
    /// session's own host, so it never leaks to a jump host.
    public static func shouldAutofillPassword(
        prompt: String,
        hostCandidates: [String],
        user: String?,
        hasJumpHost: Bool
    ) -> Bool {
        guard classify(prompt, hint: nil) == .password else { return false }
        guard let target = mentionedTarget(in: prompt) else {
            // Bare "Password:" — ambiguous when a jump host is involved.
            return !hasJumpHost
        }
        let hostMatches = hostCandidates.contains { $0.caseInsensitiveCompare(target.host) == .orderedSame }
        guard hostMatches else { return false }
        if let promptUser = target.user, let user, !user.isEmpty {
            return promptUser == user
        }
        return true
    }
}
