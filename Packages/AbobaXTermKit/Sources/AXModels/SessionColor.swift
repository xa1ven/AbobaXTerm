import Foundation

/// Accent color of a session; mapped to a system color in the UI layer.
public enum SessionColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
}

/// SF Symbols offered for sessions.
public enum SessionIcon {
    public static let `default` = "terminal"
    public static let all: [String] = [
        "terminal", "server.rack", "desktopcomputer", "laptopcomputer", "cloud",
        "cpu", "network", "externaldrive", "house", "building.2", "shield",
        "globe", "flask", "hammer", "gamecontroller", "display",
    ]
}
