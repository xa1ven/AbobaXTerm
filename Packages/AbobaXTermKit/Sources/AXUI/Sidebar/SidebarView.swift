import AXL10n
import AXModels
import SwiftUI

/// One visible row of the sessions tree, with what is needed to draw the
/// connecting lines to its parent folder.
struct SidebarNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder(Folder)
        case session(Session)
    }

    let kind: Kind
    /// For every ancestor level: whether that ancestor has more siblings
    /// below, i.e. its vertical line continues through this row.
    let continues: [Bool]
    /// Last child of its parent: the line stops at this row.
    let isLast: Bool

    var depth: Int { continues.count }

    var id: SidebarItem {
        switch kind {
        case .folder(let f): .folder(f.id)
        case .session(let s): .session(s.id)
        }
    }

    /// Flattens the library into rows; only expanded folders show their contents.
    static func rows(_ library: SessionLibrary, expanded: Set<UUID>, parent: UUID? = nil, continues: [Bool] = []) -> [SidebarNode] {
        let kinds = library.childFolders(of: parent).map(Kind.folder) + library.sessions(in: parent).map(Kind.session)
        var result: [SidebarNode] = []
        for (index, kind) in kinds.enumerated() {
            let isLast = index == kinds.count - 1
            result.append(SidebarNode(kind: kind, continues: continues, isLast: isLast))
            if case .folder(let folder) = kind, expanded.contains(folder.id) {
                // Top-level rows have no line of their own to continue.
                result += rows(library, expanded: expanded, parent: folder.id, continues: continues + [!isLast])
            }
        }
        return result
    }
}

/// Explorer-style connecting lines in front of a nested row.
private struct TreeGuides: View {
    let node: SidebarNode
    static let step: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let depth = node.depth
            for level in 1..<max(depth, 1) where node.continues[level] {
                let x = (CGFloat(level) - 0.5) * Self.step
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            if depth > 0 {
                let x = (CGFloat(depth) - 0.5) * Self.step
                let middle = (size.height / 2).rounded()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: node.isLast ? middle : size.height))
                path.move(to: CGPoint(x: x, y: middle))
                path.addLine(to: CGPoint(x: size.width - 2, y: middle))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
        }
        .frame(width: CGFloat(node.depth) * Self.step)
        // Rows are separated by a few points of padding; reach across it so
        // the vertical lines of neighbouring rows join.
        .padding(.vertical, -6)
        .allowsHitTesting(false)
    }
}

/// Sidebar: session search on top, then the Sessions | SFTP switcher.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Picker(L("Sidebar"), selection: $model.sidebarMode) {
                Label(L("Sessions"), systemImage: "server.rack").tag(SidebarMode.sessions)
                Label(L("SFTP"), systemImage: "folder").tag(SidebarMode.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            switch model.sidebarMode {
            case .sessions:
                SessionsListView()
            case .files:
                if let tab = model.selectedTab, let browser = model.selectedFileBrowser {
                    FileBrowserPanel(browser: browser, tab: tab)
                        .id(tab.id)
                } else {
                    ContentUnavailableView {
                        Label(L("No SFTP Session"), systemImage: "folder")
                    } description: {
                        Text(L("Open an SSH session to browse its files here."))
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: L("Search sessions"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 600)
    }
}

/// Saved sessions: favorites and the folder tree, or search results.
private struct SessionsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let library = model.library
        let isSearching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty

        List(selection: $model.sidebarSelection) {
            if isSearching {
                let results = library.search(model.searchText)
                Section(L("Results (%@)", results.count)) {
                    ForEach(results) { session in
                        sessionRow(session, item: .session(session.id), folderPath: library.path(of: session.folderID))
                            .tag(SidebarItem.session(session.id))
                    }
                }
            } else {
                let favorites = library.favorites
                if !favorites.isEmpty {
                    Section(L("Favorites")) {
                        ForEach(favorites) { session in
                            sessionRow(session, item: .favorite(session.id))
                                .tag(SidebarItem.favorite(session.id))
                        }
                    }
                }
                Section {
                    ForEach(SidebarNode.rows(library, expanded: model.expandedFolders)) { node in
                        HStack(spacing: 0) {
                            TreeGuides(node: node)
                            row(for: node)
                        }
                        .background { selectionMark(node.id) }
                        .tag(node.id)
                    }
                } header: {
                    Text(L("Sessions"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { items, _ in
                            model.handleDrop(items, into: nil)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.rightArrow) { setSelectedFolder(collapsed: false) }
        .onKeyPress(.leftArrow) { setSelectedFolder(collapsed: true) }
        .background(SidebarTableBridge(onEmptyAreaClick: { model.focusTerminal() }, onFocusChange: { focused in
            // The selection belongs to the focused sidebar only.
            if !focused { model.sidebarSelection = nil }
        }))
        // Double-click is handled by the rows themselves (see `click`).
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            SidebarContextMenu(item: items.first)
        }
        .overlay {
            if library.sessions.isEmpty && library.folders.isEmpty {
                ContentUnavailableView {
                    Label(L("No Sessions"), systemImage: "server.rack")
                } description: {
                    Text(L("Create a session to connect over SSH."))
                } actions: {
                    Button(L("New Session")) { model.newSession() }
                }
            }
        }
        .onDeleteCommand {
            switch model.sidebarSelection {
            case .session(let id), .favorite(let id): model.requestDeleteSession(id)
            case .folder(let id): model.requestDeleteFolder(id)
            case nil: break
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                SidebarBarButton(symbol: "plus", help: L("New Session (⌘N)")) {
                    model.newSession(in: model.selectedFolderForNewItems)
                }
                SidebarBarButton(symbol: "folder.badge.plus", help: L("New Folder (⇧⌘N)")) {
                    model.requestNewFolder(parent: model.selectedFolderForNewItems)
                }
                Spacer()
                Text(LN(library.sessions.count, "%@ session", "%@ sessions"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func row(for node: SidebarNode) -> some View {
        switch node.kind {
        case .folder(let folder):
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(model.expandedFolders.contains(folder.id) ? 90 : 0))
                    .frame(width: 16, height: 22)
                    .foregroundStyle(.secondary)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(folder.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // A click anywhere on the row opens or closes the folder. The tap
            // takes the click from the list, so select the row here as well.
            .onTapGesture {
                click(.folder(folder.id))
                setCollapsed(model.expandedFolders.contains(folder.id), folder.id)
            }
            .draggable(SidebarItem.folder(folder.id).dragPayload)
            .dropDestination(for: String.self) { items, _ in
                model.handleDrop(items, into: folder.id)
            }
        case .session(let session):
            sessionRow(session, item: .session(session.id))
        }
    }

    /// Session row that takes clicks over its whole width. Rows handle clicks
    /// themselves: left to the list, a click on the draggable part of a row
    /// was sometimes swallowed by the drag gesture.
    private func sessionRow(_ session: Session, item: SidebarItem, folderPath: String = "") -> some View {
        SessionRow(session: session, folderPath: folderPath)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { click(item) }
            // After the tap gesture: a drag attached inside it kept clicks on
            // the empty part of the row from reaching the tap.
            .draggable(SidebarItem.session(session.id).dragPayload) {
                Label(session.displayName, systemImage: session.iconName)
                    .padding(6)
            }
            .background { if !isTreeItem(item) { selectionMark(item) } }
    }

    /// Tree rows draw the mark behind the guides as well, one level up.
    private func isTreeItem(_ item: SidebarItem) -> Bool {
        if case .session = item { return model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }

    /// Selects the row; a double-click on a session connects to it.
    private func click(_ item: SidebarItem) {
        model.sidebarSelection = item
        if NSApp.currentEvent?.clickCount == 2, let id = item.sessionID {
            model.connect(sessionID: id)
        }
    }

    /// Neutral gray selection mark, drawn by the app in place of the list's
    /// own accent-colored highlight (which `SidebarTableBridge` turns off).
    @ViewBuilder
    private func selectionMark(_ item: SidebarItem) -> some View {
        if model.sidebarSelection == item {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
        }
    }

    private func setCollapsed(_ value: Bool, _ id: UUID) {
        withAnimation(.snappy(duration: 0.18)) {
            if value { model.expandedFolders.remove(id) } else { model.expandedFolders.insert(id) }
        }
    }

    /// ← and → collapse and expand the selected folder, as in Finder.
    private func setSelectedFolder(collapsed value: Bool) -> KeyPress.Result {
        guard case .folder(let id) = model.sidebarSelection, model.expandedFolders.contains(id) == value else { return .ignored }
        setCollapsed(value, id)
        return .handled
    }
}

/// Large, easy-to-hit icon button for the sidebar bottom bar.
private struct SidebarBarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    var folderPath: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.iconName)
                .foregroundStyle(session.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.displayName)
                        .lineLimit(1)
                    if session.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(folderPath.isEmpty ? session.target : "\(folderPath) · \(session.target)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.isConnected(session.id) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 8)
                    .help(L("Connected"))
            }
        }
        .padding(.vertical, 2)
    }
}

struct SidebarContextMenu: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem?

    var body: some View {
        switch item {
        case .session(let id), .favorite(let id):
            if let session = model.library.session(id: id) {
                Button(L("Connect")) { model.connect(sessionID: id) }
                Divider()
                Button(L("Edit…")) { model.editSession(id) }
                Button(L("Duplicate")) { model.duplicateSession(id) }
                Button(session.isFavorite ? L("Remove from Favorites") : L("Add to Favorites")) { model.toggleFavorite(id) }
                Menu(L("Move to")) {
                    Button(L("Top Level")) { model.move(sessionID: id, to: nil) }
                        .disabled(session.folderID == nil)
                    let folders = model.library.folders.sorted {
                        model.library.path(of: $0.id).localizedStandardCompare(model.library.path(of: $1.id)) == .orderedAscending
                    }
                    if !folders.isEmpty { Divider() }
                    ForEach(folders) { folder in
                        Button(model.library.path(of: folder.id)) { model.move(sessionID: id, to: folder.id) }
                            .disabled(session.folderID == folder.id)
                    }
                }
                Button(L("Copy SSH Command")) { model.copyCommandLine(id) }
                Divider()
                Button(L("Delete…"), role: .destructive) { model.requestDeleteSession(id) }
            }
        case .folder(let id):
            Button(L("New Session Here…")) { model.newSession(in: id) }
            Button(L("New Subfolder")) { model.requestNewFolder(parent: id) }
            Divider()
            Button(L("Rename…")) { model.requestRenameFolder(id) }
            Button(L("Move to Top Level")) { model.move(folderID: id, to: nil) }
            Divider()
            Button(L("Delete Folder…"), role: .destructive) { model.requestDeleteFolder(id) }
        case nil:
            Button(L("New Session…")) { model.newSession() }
            Button(L("New Folder")) { model.requestNewFolder() }
        }
    }
}

extension AppModel {
    /// Folder that new sessions/folders go into: the selected folder, or the
    /// folder of the selected session.
    var selectedFolderForNewItems: UUID? {
        switch sidebarSelection {
        case .folder(let id): id
        case .session(let id): library.session(id: id)?.folderID
        default: nil
        }
    }
}
