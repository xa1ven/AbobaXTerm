import Foundation

/// A saved SSH session.
///
/// `port` and `user` are optional on purpose: when they are nil, ssh takes them
/// from ~/.ssh/config (so `host` may simply be a `Host` alias from that file).
public struct Session: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int?
    public var user: String?
    public var auth: AuthMethod
    /// Value for `-J` (ProxyJump), e.g. `admin@bastion:2222,other`.
    public var jumpHost: String?
    /// Extra ssh arguments, shell-quoted, e.g. `-o ServerAliveInterval=30`.
    public var extraOptions: String
    public var x11Forwarding: Bool
    public var folderID: UUID?
    public var isFavorite: Bool
    public var color: SessionColor?
    /// SF Symbol name.
    public var icon: String?
    public var notes: String
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int? = nil,
        user: String? = nil,
        auth: AuthMethod = .system,
        jumpHost: String? = nil,
        extraOptions: String = "",
        x11Forwarding: Bool = false,
        folderID: UUID? = nil,
        isFavorite: Bool = false,
        color: SessionColor? = nil,
        icon: String? = nil,
        notes: String = "",
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.jumpHost = jumpHost
        self.extraOptions = extraOptions
        self.x11Forwarding = x11Forwarding
        self.folderID = folderID
        self.isFavorite = isFavorite
        self.color = color
        self.icon = icon
        self.notes = notes
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// Name shown in the UI; falls back to the target when the name is empty.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? target : trimmed
    }

    /// `user@host:port` with the optional parts omitted.
    public var target: String {
        var s = ""
        if let user, !user.isEmpty { s += "\(user)@" }
        s += host.contains(":") && port != nil ? "[\(host)]" : host
        if let port { s += ":\(port)" }
        return s
    }

    /// Case-insensitive match against name, host, user and notes.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [name, host, user ?? "", notes, jumpHost ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension Session: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, user, auth, jumpHost, extraOptions, x11Forwarding
        case folderID, isFavorite, color, icon, notes, createdAt, lastConnectedAt
    }

    // Tolerant decoding: missing keys fall back to defaults so that older or
    // hand-edited JSON files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        auth = try c.decodeIfPresent(AuthMethod.self, forKey: .auth) ?? .system
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost)
        extraOptions = try c.decodeIfPresent(String.self, forKey: .extraOptions) ?? ""
        x11Forwarding = try c.decodeIfPresent(Bool.self, forKey: .x11Forwarding) ?? false
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        color = try? c.decodeIfPresent(SessionColor.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }
}
