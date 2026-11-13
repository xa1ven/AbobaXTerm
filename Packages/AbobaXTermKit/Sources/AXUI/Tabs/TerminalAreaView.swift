import AXL10n
import AXModels
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
                // Below the terminal, not over it: the last lines usually
                // say why the connection ended.
                DisconnectedBar(tab: tab)
                    .id(tab.id)
                if model.monitorEnabled, let monitor = model.monitors[tab.id] {
                    VStack(spacing: 0) {
                        Divider()
                        ServerStatusBar(tab: tab, monitor: monitor)
                    }
                    .id(tab.id)
                    .transition(Motion.bar(from: .bottom))
                }
            } else {
                EmptyStateView()
            }
        }
        // View > Show/Hide Status Bar.
        .animation(Motion.standard, value: model.monitorEnabled)
    }
}

/// Strip under a terminal whose shell or connection has ended.
private struct DisconnectedBar: View {
    let tab: TerminalTab

    var body: some View {
        VStack(spacing: 0) {
            switch tab.state {
            case .exited(let code):
                let what = tab.isLocal ? L("Shell exited") : (code == 0 ? L("Session ended") : L("Connection closed"))
                bar(text: code == 0 || code == nil ? what : L("%@ (exit code %@)", what, code!),
                    icon: "bolt.horizontal.circle", tint: .secondary)
            case .failed(let message):
                bar(text: message, icon: "exclamationmark.triangle.fill", tint: .orange)
            default:
                EmptyView()
            }
        }
        .animation(Motion.standard, value: tab.state.isActive)
    }

    private func bar(text: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Button(tab.isLocal ? L("Restart Shell  ⌘R") : L("Reconnect  ⌘R")) { tab.reconnect() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .transition(Motion.bar(from: .bottom))
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(L("No Open Sessions"))
                .font(.title2.weight(.semibold))
            Text(L("Double-click a session in the sidebar to connect, or open a terminal on this Mac."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button(L("New Session…")) { model.newSession() }
                Button(L("New Local Terminal")) { model.openLocalTerminal() }
                    .buttonStyle(.borderedProminent)
            }
            let recent = model.recentSessions
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Recent"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                        .padding(.bottom, 2)
                    ForEach(recent) { session in
                        RecentSessionRow(session: session)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A recent session on the empty screen: the name in the label color, the
/// address dimmer, a highlight under the pointer.
private struct RecentSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var hovering = false

    var body: some View {
        Button {
            model.connect(sessionID: session.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: session.iconName)
                    .foregroundStyle(session.tint)
                    .frame(width: 18)
                Text(session.displayName)
                    .foregroundStyle(.primary)
                Text(session.target)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Connect"))
    }
}
