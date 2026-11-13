import AXL10n
import AXModels
import Foundation

/// Summary of an SSH session shown in the terminal once it is connected:
/// where it goes, how it signed in and which extras of the app are active.
public struct SessionBanner: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public enum Mark: Equatable, Sendable {
            /// Plain fact, no mark.
            case info
            case on
            case off
            case failed
        }

        public var label: String
        public var value: String
        public var mark: Mark

        public init(_ label: String, _ value: String, _ mark: Mark = .info) {
            self.label = label
            self.value = value
            self.mark = mark
        }
    }

    /// What the app knows about the connection besides the session itself.
    public struct Context: Sendable {
        public var appVersion: String
        /// Effective settings from `ssh -G`.
        public var resolved: ResolvedSSHConfig?
        /// Comment of the public key in use ("user@machine").
        public var keyComment: String?
        /// The tab rides on a master connection that is already open.
        public var isShared = false
        /// nil: X11 forwarding is off; false: on, but no local X server.
        public var x11Ready: Bool?
        public var monitoring = true
        public var isSaved = true

        public init(appVersion: String, resolved: ResolvedSSHConfig? = nil) {
            self.appVersion = appVersion
            self.resolved = resolved
        }
    }

    public var title: String
    public var destination: String
    /// Dim note after the destination, e.g. the port.
    public var note: String?
    public var rows: [Row]

    public init(title: String, destination: String, note: String? = nil, rows: [Row]) {
        self.title = title
        self.destination = destination
        self.note = note
        self.rows = rows
    }

    public init(session: Session, context: Context) {
        let resolved = context.resolved
        let host = session.host.trimmingCharacters(in: .whitespaces)
        let user = resolved?.user ?? session.user ?? NSUserName()
        title = "AbobaXTerm " + context.appVersion
        destination = "\(user)@\(host)"

        var notes: [String] = []
        if let name = resolved?.hostName, name != host { notes.append(name) }
        if let port = resolved?.port ?? session.port, port != 22 { notes.append(L("port %@", port)) }
        note = notes.isEmpty ? nil : notes.joined(separator: ", ")

        var rows: [Row] = []
        let jump = session.jumpHost?.trimmingCharacters(in: .whitespaces)
        if let jump = (jump?.isEmpty == false ? jump : nil) ?? resolved?.proxyJump {
            rows.append(Row(L("Route"), L("through %@", jump)))
        } else {
            rows.append(Row(L("Route"), L("direct")))
        }

        switch session.auth {
        case .password:
            rows.append(Row(L("Sign-in"), L("password")))
        case .publicKey(let path):
            let name = (path as NSString).lastPathComponent
            let comment = context.keyComment.map { " (\($0))" } ?? ""
            rows.append(Row(L("Sign-in"), L("key %@", name) + comment))
        case .system:
            rows.append(Row(L("Sign-in"), L("ssh-agent or default keys")))
        }

        // Only worth a line when it explains why there was no sign-in prompt.
        if context.isShared {
            rows.append(Row(L("Connection"), L("shared with a tab that is already open")))
        }
        if let compression = resolved?.compression {
            rows.append(Row(L("Compression"), compression ? L("on") : L("off"), compression ? .on : .off))
        }
        rows.append(Row(L("Files"), L("SFTP panel on the left"), .on))
        switch context.x11Ready {
        case true?: rows.append(Row("X11", L("windows open on this Mac"), .on))
        case false?: rows.append(Row("X11", L("no X server, windows will not open"), .failed))
        case nil: rows.append(Row("X11", L("off"), .off))
        }
        rows.append(Row(L("Monitoring"), context.monitoring ? L("status bar below") : L("off"),
                        context.monitoring ? .on : .off))
        if context.isSaved {
            let last = session.lastConnectedAt.map {
                $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: L10n.shared.language.rawValue)))
            }
            rows.append(Row(L("Last visit"), last ?? L("first time")))
        }
        self.rows = rows
    }

    // MARK: Rendering

    /// Narrower terminals get plain lines without the frame.
    public static let minimumFramedColumns = 56

    /// Text for the terminal, lines separated by CR LF.
    /// - Parameter color: false leaves out the escape sequences (tests, logs).
    public func render(columns: Int, color: Bool = true) -> String {
        func paint(_ text: String, _ code: String) -> String {
            color && !text.isEmpty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
        }
        let labelWidth = rows.map(\.label.count).max() ?? 0

        // (plain text, painted text) for every line of content.
        var lines: [(plain: String, painted: String)] = []
        let noteText = note.map { "  " + $0 } ?? ""
        lines.append(("▸ " + destination + noteText,
                      paint("▸", "36") + " " + paint(destination, "1") + paint(noteText, "2")))
        lines.append(("", ""))
        for row in rows {
            let label = row.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            let mark: (plain: String, painted: String) = switch row.mark {
            case .info: ("", "")
            case .on: ("✓ ", paint("✓", "32") + " ")
            case .off: ("– ", paint("–", "2") + " ")
            case .failed: ("✗ ", paint("✗", "31") + " ")
            }
            let value = row.mark == .off ? paint(row.value, "2") : row.value
            lines.append(("  \(label)  \(mark.plain)\(row.value)", "  " + paint(label, "2") + "  " + mark.painted + value))
        }

        let framed = columns >= Self.minimumFramedColumns
        guard framed else {
            let body = [(title, paint(title, "1"))] + lines
            return body.map(\.1).joined(separator: "\r\n") + "\r\n\r\n"
        }

        // Frame: " │ " + content + " │", one column of margin on the left.
        let inner = min(max(lines.map(\.plain.count).max() ?? 0, title.count + 4, 44), columns - 6)
        var out: [String] = []
        let head = "─ \(title) "
        out.append(" " + paint("╭─", "2") + " " + paint(title, "1") + " "
                   + paint(String(repeating: "─", count: max(inner + 2 - head.count, 0)) + "╮", "2"))
        let bar = paint("│", "2")
        for line in [("", "")] + lines + [("", "")] {
            var plain = line.0
            var painted = line.1
            if plain.count > inner {
                // Too long for the terminal: cut, and drop the colors with the tail.
                plain = String(plain.prefix(inner - 1)) + "…"
                painted = plain
            }
            out.append(" \(bar) \(painted)\(String(repeating: " ", count: inner - plain.count)) \(bar)")
        }
        out.append(" " + paint("╰" + String(repeating: "─", count: inner + 2) + "╯", "2"))
        return out.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// The comment field of an OpenSSH public key file ("type base64 comment").
    public static func keyComment(publicKeyFile contents: String) -> String? {
        let parts = contents.split(separator: "\n").first?.split(separator: " ", maxSplits: 2) ?? []
        guard parts.count == 3 else { return nil }
        let comment = parts[2].trimmingCharacters(in: .whitespaces)
        return comment.isEmpty ? nil : comment
    }
}
