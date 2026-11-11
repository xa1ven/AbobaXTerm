import AXModels
import SwiftUI

/// Tree node for the sessions outline.
struct SidebarNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder(Folder)
        case session(Session)
    }

    let kind: Kind
    var children: [SidebarNode]?

    var id: SidebarItem {
        switch kind {
        case .folder(let f): .folder(f.id)
        case .session(let s): .session(s.id)
        }
    }

    static func tree(_ library: SessionLibrary, parent: UUID? = nil) -> [SidebarNode] {
        library.childFolders(of: parent).map { folder in
            SidebarNode(kind: .folder(folder), children: tree(library, parent: folder.id))
        } + library.sessions(in: parent).map { SidebarNode(kind: .session($0), children: nil) }
    }
}

/// Sidebar: session search on top, then the Sessions | SFTP switcher.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Picker("Sidebar", selection: $model.sidebarMode) {
                Label("Sessions", systemImage: "server.rack").tag(SidebarMode.sessions)
                Label("SFTP", systemImage: "folder").tag(SidebarMode.files)
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
                        Label("No SFTP Session", systemImage: "folder")
                    } description: {
                        Text("Open an SSH session to browse its files here.")
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search sessions")
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
                Section("Results (\(results.count))") {
                    ForEach(results) { session in
                        SessionRow(session: session, folderPath: library.path(of: session.folderID))
                            .tag(SidebarItem.session(session.id))
                    }
                }
            } else {
                let favorites = library.favorites
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { session in
                            SessionRow(session: session)
                                .tag(SidebarItem.favorite(session.id))
                        }
                    }
                }
                Section {
                    OutlineGroup(SidebarNode.tree(library), children: \.children) { node in
                        row(for: node)
                    }
                } header: {
                    Text("Sessions")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { items, _ in
                            model.handleDrop(items, into: nil)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .background(EmptyAreaClickMonitor { model.focusTerminal() })
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            SidebarContextMenu(item: items.first)
        } primaryAction: { items in
            guard let item = items.first else { return }
            switch item {
            case .session(let id), .favorite(let id): model.connect(sessionID: id)
            case .folder(let id): model.requestRenameFolder(id)
            }
        }
        .overlay {
            if library.sessions.isEmpty && library.folders.isEmpty {
                ContentUnavailableView {
                    Label("No Sessions", systemImage: "server.rack")
                } description: {
                    Text("Create a session to connect over SSH.")
                } actions: {
                    Button("New Session") { model.newSession() }
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
                SidebarBarButton(symbol: "plus", help: "New Session (⌘N)") {
                    model.newSession(in: model.selectedFolderForNewItems)
                }
                SidebarBarButton(symbol: "folder.badge.plus", help: "New Folder (⇧⌘N)") {
                    model.requestNewFolder(parent: model.selectedFolderForNewItems)
                }
                SidebarBarButton(symbol: "apple.terminal", help: "New Local Terminal (⌘T)") {
                    model.openLocalTerminal()
                }
                Spacer()
                Text(library.sessions.count == 1 ? "1 session" : "\(library.sessions.count) sessions")
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
            Label {
                Text(folder.name)
            } icon: {
                Image(systemName: "folder")
            }
            .draggable(SidebarItem.folder(folder.id).dragPayload)
            .dropDestination(for: String.self) { items, _ in
                model.handleDrop(items, into: folder.id)
            }
        case .session(let session):
            SessionRow(session: session)
        }
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
                    .help("Connected")
            }
        }
        .padding(.vertical, 2)
        .draggable(SidebarItem.session(session.id).dragPayload) {
            Label(session.displayName, systemImage: session.iconName)
                .padding(6)
        }
    }
}

struct SidebarContextMenu: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem?

    var body: some View {
        switch item {
        case .session(let id), .favorite(let id):
            if let session = model.library.session(id: id) {
                Button("Connect") { model.connect(sessionID: id) }
                Divider()
                Button("Edit…") { model.editSession(id) }
                Button("Duplicate") { model.duplicateSession(id) }
                Button(session.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(id) }
                Menu("Move to") {
                    Button("Top Level") { model.move(sessionID: id, to: nil) }
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
                Button("Copy SSH Command") { model.copyCommandLine(id) }
                Divider()
                Button("Delete…", role: .destructive) { model.requestDeleteSession(id) }
            }
        case .folder(let id):
            Button("New Session Here…") { model.newSession(in: id) }
            Button("New Subfolder") { model.requestNewFolder(parent: id) }
            Divider()
            Button("Rename…") { model.requestRenameFolder(id) }
            Button("Move to Top Level") { model.move(folderID: id, to: nil) }
            Divider()
            Button("Delete Folder…", role: .destructive) { model.requestDeleteFolder(id) }
        case nil:
            Button("New Session…") { model.newSession() }
            Button("New Folder") { model.requestNewFolder() }
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
