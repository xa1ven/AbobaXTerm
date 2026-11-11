import AXModels
import AXSSH
import SwiftUI

/// The main window: sessions sidebar on the left, tabbed terminals on the right.
public struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
        } detail: {
            TerminalAreaView()
                .toolbar { MainToolbar() }
        }
        .navigationTitle(model.selectedTab?.title ?? "AbobaXTerm")
        .navigationSubtitle(model.selectedTab?.subtitle ?? "")
        .task {
            model.start()
            #if DEBUG
            DebugSnapshot.runIfRequested(model, openSettings: { openSettings() })
            #endif
        }
        .sheet(item: $model.editorRequest) { request in
            SessionEditorView(request: request)
        }
        .alert(
            deletionTitle,
            isPresented: Binding(get: { model.deletionRequest != nil }, set: { if !$0 { model.deletionRequest = nil } }),
            presenting: model.deletionRequest
        ) { request in
            Button("Delete", role: .destructive) { model.performDeletion(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            switch request.target {
            case .session: Text("The saved password for this session will also be removed from the Keychain.")
            case .folder: Text("Sessions and subfolders inside it are moved up one level, not deleted.")
            }
        }
        .alert(
            folderAlertTitle,
            isPresented: Binding(get: { model.folderNameRequest != nil }, set: { if !$0 { model.folderNameRequest = nil } }),
            presenting: model.folderNameRequest
        ) { request in
            FolderNameField(request: request)
        }
        .alert(
            "XQuartz Is Not Installed",
            isPresented: Binding(get: { model.x11MissingRequest != nil }, set: { if !$0 { model.x11MissingRequest = nil } }),
            presenting: model.x11MissingRequest
        ) { session in
            Button("Connect Without X11") { model.connectWithoutX11(session) }
            Button("Copy Install Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(X11Support.installCommand, forType: .string)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“\(model.x11MissingRequest?.displayName ?? "")” uses X11 forwarding, which needs XQuartz to show windows from the server.\n\nInstall it in Terminal with:\n\(X11Support.installCommand)\nthen log out and back in.")
        }
        .alert(
            model.errorMessage?.title ?? "",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }

    private var deletionTitle: String {
        guard let request = model.deletionRequest else { return "" }
        switch request.target {
        case .session: return "Delete session “\(request.name)”?"
        case .folder: return "Delete folder “\(request.name)”?"
        }
    }

    private var folderAlertTitle: String {
        if case .rename = model.folderNameRequest?.mode { return "Rename Folder" }
        return "New Folder"
    }
}

/// Text field + buttons inside the folder name alert.
private struct FolderNameField: View {
    @Environment(AppModel.self) private var model
    @State private var name: String
    let request: FolderNameRequest

    init(request: FolderNameRequest) {
        self.request = request
        _name = State(initialValue: request.name)
    }

    var body: some View {
        TextField("Name", text: $name)
        Button("OK") {
            var updated = request
            updated.name = name
            model.commitFolderName(updated)
        }
        Button("Cancel", role: .cancel) {}
    }
}

private struct MainToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }
}
