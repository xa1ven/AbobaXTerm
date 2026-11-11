import AXModels
import AXTerminal
import SwiftUI

extension SessionColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

extension Session {
    var iconName: String { icon ?? SessionIcon.default }
    var tint: Color { color?.color ?? .accentColor }
}

extension TerminalTab {
    var iconName: String { session?.iconName ?? "apple.terminal" }
    var tint: Color { session?.tint ?? .secondary }
}
