import AXL10n
import AXTerminal
import SwiftUI

struct TabStripView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        TabButton(tab: tab, isSelected: tab.id == model.selectedTabID)
                            .id(tab.id)
                    }
                    Button {
                        model.openLocalTerminal()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(L("New Local Terminal (⌘T)"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .onChange(of: model.selectedTabID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .background(.bar)
    }
}

private struct TabButton: View {
    @Environment(AppModel.self) private var model
    let tab: TerminalTab
    let isSelected: Bool
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 14)
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hoveringClose ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    // Marks the button under the pointer, so a tab is not closed by accident.
                    .background(Color.primary.opacity(hoveringClose ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .opacity(hovering || isSelected ? 1 : 0)
            .help(L("Close Tab (⌘W)"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.14)
                      : hovering ? Color.primary.opacity(0.07) : Color.clear)
        }
        .overlay(alignment: .bottom) {
            if isSelected, let color = tab.session?.color {
                Capsule().fill(color.color).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTabID = tab.id }
        .onHover { hovering = $0 }
        .help(tab.remoteTitle.map { "\(tab.subtitle) — \($0)" } ?? tab.subtitle)
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let id = UUID(uuidString: first) else { return false }
            model.moveTab(id, before: tab.id)
            return true
        }
        .contextMenu {
            Button(tab.isLocal ? L("Restart") : L("Reconnect")) { tab.reconnect() }
                .disabled(tab.state.isActive)
            Button(L("Duplicate Tab")) { model.duplicateTab(tab.id) }
            Divider()
            Button(L("Close Tab")) { model.closeTab(tab.id) }
            Button(L("Close Other Tabs")) { model.closeOtherTabs(tab.id) }
                .disabled(model.tabs.count < 2)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tab.state {
        case .idle, .connecting:
            ProgressView().controlSize(.mini)
        case .running:
            Image(systemName: tab.iconName)
                .font(.caption)
                .foregroundStyle(tab.tint)
        case .exited:
            Image(systemName: "bolt.horizontal.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
