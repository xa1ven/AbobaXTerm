import Foundation

/// How copy and paste are done in an X program, judged by its WM_CLASS.
enum X11ShortcutStyle: Equatable, Sendable {
    /// Regular programs: Control+C, Control+V and so on.
    case standard
    /// Terminals where Control+C interrupts and copy/paste are Control+Shift+C / V.
    case terminal
    /// Classic terminals: selecting text puts it in PRIMARY, Shift+Insert pastes PRIMARY.
    case selectionTerminal

    private static let selectionTerminals: Set<String> = [
        "xterm", "uxterm", "urxvt", "rxvt", "rxvt-unicode", "mrxvt", "st", "st-256color",
        "aterm", "eterm", "mlterm", "kterm", "wterm", "xvt",
    ]

    private static let terminals: Set<String> = [
        "gnome-terminal", "gnome-terminal-server", "kgx", "ptyxis", "xfce4-terminal", "mate-terminal",
        "lxterminal", "qterminal", "konsole", "terminator", "tilix", "guake", "tilda", "sakura", "roxterm",
        "terminology", "termite", "kitty", "alacritty", "wezterm", "org.wezfurlong.wezterm", "ghostty",
        "com.mitchellh.ghostty", "deepin-terminal", "io.elementary.terminal", "cool-retro-term",
        "x-terminal-emulator",
    ]

    init(instanceName: String?, className: String?) {
        let names = [instanceName, className].compactMap { $0?.lowercased() }
        if names.contains(where: Self.selectionTerminals.contains) {
            self = .selectionTerminal
        } else if names.contains(where: Self.terminals.contains) {
            self = .terminal
        } else {
            self = .standard
        }
    }
}

/// What a Command shortcut turns into on the X side.
enum X11ShortcutAction: Equatable, Sendable {
    /// The same key with Control (plus Shift when `shift`) instead of Command.
    case control(shift: Bool)
    /// Put the program's primary selection on the Mac pasteboard; no key is sent.
    case copySelection
    /// Offer the Mac pasteboard as the primary selection and send Shift+Insert.
    case pasteSelection
    /// Swallow the key: its Control twin would do harm (Control+Z suspends the shell).
    case ignore
}

/// Items of the app's Edit menu that an X window answers.
enum X11EditCommand: CaseIterable, Sendable {
    case undo, cut, copy, paste, selectAll

    /// Keysym of the letter whose Command shortcut does the same.
    var keysym: UInt32 {
        switch self {
        case .undo: 0x7A
        case .cut: 0x78
        case .copy: 0x63
        case .paste: 0x76
        case .selectAll: 0x61
        }
    }
}

enum X11Shortcut {
    /// What an Edit menu item does in a program of this style; nil when the
    /// item has no safe equivalent there (it is shown disabled).
    static func action(for command: X11EditCommand, style: X11ShortcutStyle) -> X11ShortcutAction? {
        let action = action(forKeysym: command.keysym, style: style)
        return action == .ignore ? nil : action
    }

    /// The action for Command plus the key that types `keysym` in the Latin
    /// layout, or nil when the key should go through as Super+key.
    static func action(forKeysym keysym: UInt32, style: X11ShortcutStyle) -> X11ShortcutAction? {
        guard let scalar = Unicode.Scalar(keysym), keysym < 0x80 else { return nil }
        let letter = Character(scalar)
        switch (style, letter) {
        case (.standard, "c"), (.standard, "v"), (.standard, "x"), (.standard, "a"), (.standard, "z"):
            return .control(shift: false)
        case (.terminal, "c"), (.terminal, "v"):
            return .control(shift: true)
        case (.selectionTerminal, "c"):
            return .copySelection
        case (.selectionTerminal, "v"):
            return .pasteSelection
        case (.terminal, "x"), (.terminal, "a"), (.terminal, "z"),
             (.selectionTerminal, "x"), (.selectionTerminal, "a"), (.selectionTerminal, "z"):
            return .ignore
        default:
            return nil
        }
    }
}
