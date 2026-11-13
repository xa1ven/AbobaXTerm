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
                            .transition(Motion.item)
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
                // Tabs opening, closing and changing places; not the selection.
                .animation(Motion.standard, value: model.tabs.map(\.id))
            }
            .onChange(of: model.selectedTabID) { _, id in
                if let id { withAnimation(Motion.standard) { proxy.scrollTo(id) } }
            }
        }
        .background(.bar)
    }
}

private struct TabButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    let tab: TerminalTab
    let isSelected: Bool
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 14)
                .animation(Motion.standard, value: tab.state.isActive)
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
                // The selected tab reads by its text as well as by its fill.
                .fontWeight(isSelected ? .medium : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: 180, alignment: .leading)
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hoveringClose ? .primary : .secondary)
                    .frame(width: 20, height: 20)
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
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.14), lineWidth: 1)
            }
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
            Button(tab.isLocal ? L("Restart Shell") : L("Reconnect")) { tab.reconnect() }
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
                .transition(.opacity)
        default:
            // One image for every settled state, so the symbol morphs from
            // one into the other instead of blinking.
            Image(systemName: settledIcon)
                .font(.caption)
                .foregroundStyle(settledTint)
                .contentTransition(.symbolEffect(.replace))
                // A failed connection asks for a glance, once.
                .symbolEffect(.bounce, options: .nonRepeating, value: isFailed)
                .transition(Motion.item)
                .animation(Motion.standard, value: settledIcon)
        }
    }

    private var isFailed: Bool {
        if case .failed = tab.state { true } else { false }
    }

    private var settledIcon: String {
        switch tab.state {
        case .exited: "bolt.horizontal.circle"
        case .failed: "exclamationmark.triangle.fill"
        default: tab.iconName
        }
    }

    private var settledTint: Color {
        switch tab.state {
        case .exited: .secondary
        case .failed: .orange
        default: tab.tint
        }
    }
}
