import Foundation

extension Session {
    /// Parses quick-connect input: `host`, `user@host`, `user@host:port`,
    /// `[v6addr]:port`, optionally prefixed with `ssh://`.
    public static func parseQuickConnect(_ input: String) -> Session? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("ssh://") { text.removeFirst(6) }
        if text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }

        var user: String?
        if let at = text.lastIndex(of: "@") {
            user = String(text[..<at])
            text = String(text[text.index(after: at)...])
            if user?.isEmpty == true { return nil }
        }

        var host = text
        var port: Int?
        if text.hasPrefix("[") {
            // [ipv6]:port
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()) else { return nil }
                port = p
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = String(text[..<colon])
            guard let p = Int(text[text.index(after: colon)...]) else { return nil }
            port = p
        }
        // More than one colon without brackets: bare IPv6 address, no port.

        guard !host.isEmpty, !host.hasPrefix("-") else { return nil }
        if let port, !(1...65535).contains(port) { return nil }
        return Session(name: "", host: host, port: port, user: user)
    }
}
