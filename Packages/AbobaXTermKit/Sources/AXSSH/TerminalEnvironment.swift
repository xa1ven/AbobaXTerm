import Foundation

/// Environment for processes started in the app's terminals (ssh or a local shell).
public enum TerminalEnvironment {
    /// Terminal type announced to the programs in a tab.
    public static let term = "xterm-256color"

    /// The app's environment, cleaned up for a PTY child, plus `extra`.
    public static func make(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("TERM_") || key.hasPrefix("__XPC_") {
            env.removeValue(forKey: key)
        }
        env["TERM"] = term
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "AbobaXTerm"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.merge(extra) { $1 }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// Login shell of the current user (from the user database), e.g. /bin/zsh.
    public static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
