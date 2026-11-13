import AXL10n
import Foundation

/// Card printed at the top of a local terminal tab: what runs in it, the
/// app's keyboard shortcuts and a note about the app itself.
public struct LocalBanner: Equatable, Sendable {
    /// One cell of a row: a shortcut with what it does, or plain text (empty `keys`).
    public struct Hint: Equatable, Sendable {
        public var keys: String
        public var text: String

        public init(_ keys: String, _ text: String) {
            self.keys = keys
            self.text = text
        }

        var plain: String { keys.isEmpty ? text : keys + " " + text }
    }

    public struct Row: Equatable, Sendable {
        public var label: String
        /// Lines of the row; the cells of all lines are aligned in columns.
        public var lines: [[Hint]]

        public init(_ label: String, _ lines: [[Hint]]) {
            self.label = label
            self.lines = lines
        }

        public init(_ label: String, _ text: String) {
            self.init(label, [[Hint("", text)]])
        }
    }

    public enum AgentKeys: Equatable, Sendable {
        case count(Int)
        case noAgent
        case unknown
    }

    /// What is known about this Mac when the tab opens.
    public struct Facts: Equatable, Sendable {
        /// Name of the login shell, e.g. "zsh".
        public var shell: String
        public var term: String
        /// e.g. "OpenSSH 9.9"
        public var sshVersion: String?
        public var agentKeys = AgentKeys.unknown

        public init(shell: String, term: String, sshVersion: String? = nil, agentKeys: AgentKeys = .unknown) {
            self.shell = shell
            self.term = term
            self.sshVersion = sshVersion
            self.agentKeys = agentKeys
        }
    }

    public static let website = "https://abobaxterm.site"

    public var title: String
    public var subtitle: String
    /// Rows in groups; a blank line separates two groups.
    public var groups: [[Row]]
    public var noticeTitle: String
    public var notice: String
    public var linkLabel: String
    public var link: String

    public init(appVersion: String, facts: Facts) {
        title = "• AbobaXTerm \(appVersion) •"
        subtitle = "(" + L("SSH client, SFTP browser and X server") + ")"

        var info = [Row(L("Shell"), L("%@ (login), TERM %@", facts.shell, facts.term))]
        var ssh: [String] = []
        if let version = facts.sshVersion { ssh.append(version) }
        switch facts.agentKeys {
        case .count(0): ssh.append(L("no keys in agent"))
        case .count(let count): ssh.append(LN(count, "%@ key in agent", "%@ keys in agent"))
        case .noAgent: ssh.append(L("ssh-agent is not running"))
        case .unknown: break
        }
        if !ssh.isEmpty { info.append(Row("SSH", ssh.joined(separator: ", "))) }

        // Shortcuts of the app's menus (AXUI/AppCommands.swift).
        let keys = [
            Row(L("Tabs"), [
                [Hint("⌘T", L("local terminal")), Hint("⌘N", L("new session")), Hint("⌘W", L("close"))],
                [Hint("⌘1…9", L("go to tab")), Hint("⇧⌘[ ⇧⌘]", L("previous / next"))],
                [Hint("⇧⌘D", L("duplicate")), Hint("⌘R", L("restart shell"))],
            ]),
            Row(L("View"), [[Hint("⇧⌘B", L("sessions / SFTP")), Hint("⌘+ ⌘− ⌘0", L("text size"))]]),
            Row(L("Links"), [[Hint("", L("⌘-click opens a link"))]]),
        ]
        groups = [info, keys]

        noticeTitle = "• " + L("Important:")
        notice = L("AbobaXTerm is a fan-made MobaXterm-inspired terminal for macOS, not affiliated with Mobatek. The source code is open and it is free for personal use; it is not for sale.")
        linkLabel = L("More information:")
        link = Self.website
    }

    // MARK: Rendering

    /// Text for the terminal, lines separated by CR LF.
    /// - Parameter color: false leaves out the escape sequences (tests, logs).
    public func render(columns: Int, color: Bool = true) -> String {
        func paint(_ text: String, _ code: String) -> String {
            color && !text.isEmpty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
        }
        typealias Line = (plain: String, painted: String)

        let labelWidth = groups.joined().map(\.label.count).max() ?? 0
        var rowLines: [Line] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { rowLines.append(("", "")) }
            for row in group {
                let cells = row.lines.map(\.count).max() ?? 0
                let widths = (0..<cells).map { cell in
                    // The last cell of a line has nothing after it to push away.
                    row.lines.compactMap { cell < $0.count - 1 ? $0[cell].plain.count : nil }.max() ?? 0
                }
                for (number, hints) in row.lines.enumerated() {
                    let label = (number == 0 ? row.label : "").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
                    var plain = (number == 0 ? "▸ " : "  ") + label + " "
                    var painted = (number == 0 ? paint("▸", "36") + " " : "  ") + paint(label, "2") + " "
                    for (cell, hint) in hints.enumerated() {
                        // Three spaces between two columns.
                        let gap = cell == 0 ? 1 : widths[cell - 1] - hints[cell - 1].plain.count + 3
                        let space = String(repeating: " ", count: gap)
                        plain += space + hint.plain
                        painted += space + (hint.keys.isEmpty ? hint.text : paint(hint.keys, "1") + " " + hint.text)
                    }
                    rowLines.append((plain, painted))
                }
            }
        }

        let linkPlain = linkLabel + " " + link
        // OSC 8 marks the address as a link whatever the terminal detects itself.
        let linkPainted = linkLabel + " " + (color ? "\u{1B}]8;;\(link)\u{1B}\\" + paint(link, "4;36") + "\u{1B}]8;;\u{1B}\\" : link)

        let content = max(rowLines.map(\.plain.count).max() ?? 0, title.count, subtitle.count, linkPlain.count)
        // Frame: " │ " + content + " │", one column of margin on the left.
        guard content <= columns - 6 else {
            var lines = [paint(title, "1;33"), paint(subtitle, "33"), ""] + rowLines.map(\.painted) + ["", paint(noticeTitle, "1;31")]
            lines += Self.wrap(notice, width: max(columns - 1, 20)).map { paint($0, "36") }
            lines.append(linkPainted)
            return lines.joined(separator: "\r\n") + "\r\n\r\n"
        }

        let inner = min(max(content, 56), columns - 6)
        func centered(_ text: String, _ code: String) -> Line {
            let pad = String(repeating: " ", count: (inner - text.count) / 2)
            return (pad + text, pad + paint(text, code))
        }
        var lines: [Line] = [centered(title, "1;33"), centered(subtitle, "33"), ("", "")]
        lines += rowLines
        lines += [("", ""), (noticeTitle, paint(noticeTitle, "1;31"))]
        lines += Self.wrap(notice, width: inner).map { ($0, paint($0, "36")) }
        lines.append((linkPlain, linkPainted))

        let bar = paint("│", "2")
        var out = [" " + paint("╭" + String(repeating: "─", count: inner + 2) + "╮", "2")]
        for line in lines {
            out.append(" \(bar) \(line.painted)\(String(repeating: " ", count: inner - line.plain.count)) \(bar)")
        }
        out.append(" " + paint("╰" + String(repeating: "─", count: inner + 2) + "╯", "2"))
        return out.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// Breaks `text` at spaces into lines of at most `width` characters.
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    // MARK: Facts

    /// "OpenSSH_9.9p2, LibreSSL 3.3.6" (output of `ssh -V`) → "OpenSSH 9.9".
    public static func sshVersion(fromOutput output: String) -> String? {
        let first = output.split(whereSeparator: { $0 == "," || $0.isWhitespace }).first.map(String.init) ?? ""
        guard first.hasPrefix("OpenSSH_") else { return nil }
        let version = first.dropFirst("OpenSSH_".count).prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : "OpenSSH " + version
    }

    /// Reads the result of `ssh-add -l`: 0 lists the keys, 1 means the agent
    /// is empty, 2 that there is no agent to ask.
    public static func agentKeys(exitCode: Int32, output: String) -> AgentKeys {
        switch exitCode {
        case 0: .count(output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)
        case 1: .count(0)
        case 2: .noAgent
        default: .unknown
        }
    }

    /// Looks at this Mac: the login shell, the system ssh and the agent.
    /// Never waits longer than about a second.
    public static func gatherFacts(sshPath: String = "/usr/bin/ssh", sshAddPath: String = "/usr/bin/ssh-add") async -> Facts {
        var facts = Facts(shell: (TerminalEnvironment.userShell as NSString).lastPathComponent,
                          term: TerminalEnvironment.term)
        async let version = Self.run(sshPath, ["-V"])
        async let agent = Self.run(sshAddPath, ["-l"])
        if let result = await version { facts.sshVersion = sshVersion(fromOutput: result.output) }
        if let result = await agent { facts.agentKeys = agentKeys(exitCode: result.code, output: result.output) }
        return facts
    }

    /// Runs a short command; nil when it cannot start or takes over a second.
    private static func run(_ path: String, _ arguments: [String]) async -> (code: Int32, output: String)? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let timedOut = TimeoutFlag()
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if timedOut.value {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                guard process.isRunning else { return }
                timedOut.value = true
                process.terminate()
            }
        }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
