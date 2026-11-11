import Foundation

/// How a session authenticates against the server.
public enum AuthMethod: Hashable, Sendable {
    /// Let ssh decide: ~/.ssh/config, ssh-agent and default identity files.
    case system
    /// A specific private key file (passed as `-i`, with `IdentitiesOnly=yes`).
    case publicKey(path: String)
    /// Password / keyboard-interactive; the password is kept in the Keychain.
    case password

    public enum Kind: String, CaseIterable, Codable, Sendable {
        case system, publicKey, password
    }

    public var kind: Kind {
        switch self {
        case .system: .system
        case .publicKey: .publicKey
        case .password: .password
        }
    }
}

extension AuthMethod: Codable {
    private enum CodingKeys: String, CodingKey { case type, keyPath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .system
        switch kind {
        case .system: self = .system
        case .password: self = .password
        case .publicKey: self = .publicKey(path: try c.decodeIfPresent(String.self, forKey: .keyPath) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        if case .publicKey(let path) = self {
            try c.encode(path, forKey: .keyPath)
        }
    }
}
