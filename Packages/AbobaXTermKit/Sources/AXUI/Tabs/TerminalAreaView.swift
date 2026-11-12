import AXTerminal
import SwiftUI

/// Tab strip + the selected terminal (or the empty state).
struct TerminalAreaView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                TabStripView()
                Divider()
            }
            if let tab = model.selectedTab {
                TerminalViewRepresentable(tab: tab)
                    .id(tab.id)
                    .overlay(alignment: .bottom) {
                        DisconnectedBanner(tab: tab)
                    }
                if model.monitorEnabled, let monitor = model.monitors[tab.id] {
                    Divider()
                    ServerStatusBar(tab: tab, monitor: monitor)
                        .id(tab.id)
                }
            } else {
                EmptyStateView()
            }
        }
    }
}

private struct DisconnectedBanner: View {
    let tab: TerminalTab

    var body: some View {
        switch tab.state {
        case .exited(let code):
            let what = tab.isLocal ? "Shell exited" : (code == 0 ? "Session ended" : "Connection closed")
            banner(text: code == 0 || code == nil ? what : "\(what) (exit code \(code!))",
                   icon: "bolt.horizontal.circle")
        case .failed(let message):
            banner(text: message, icon: "exclamationmark.triangle.fill")
        default:
            EmptyView()
        }
    }

    private func banner(text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text).lineLimit(2)
            Button(tab.isLocal ? "Restart  ⌘R" : "Reconnect  ⌘R") { tab.reconnect() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 16)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Open Sessions")
                .font(.title2.weight(.semibold))
            Text("Double-click a session in the sidebar to connect, or open a terminal on this Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("New Session…") { model.newSession() }
                Button("Start Local Terminal") { model.openLocalTerminal() }
                    .buttonStyle(.borderedProminent)
            }
            let recent = model.recentSessions
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ForEach(recent) { session in
                        Button {
                            model.connect(sessionID: session.id)
                        } label: {
                            Label {
                                Text(session.displayName)
                                Text(session.target).foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: session.iconName).foregroundStyle(session.tint)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

