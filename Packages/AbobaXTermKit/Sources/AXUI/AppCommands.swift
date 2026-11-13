import AppKit
import AXL10n
import SwiftUI

/// Menu bar commands and keyboard shortcuts. Every command the interface
/// offers (toolbar, context menus, sidebar buttons) is listed here as well.
public struct AppCommands: Commands {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("About AbobaXTerm")) { AboutPanel.show() }
        }

        CommandGroup(replacing: .newItem) {
            Button(L("New Session…")) { model.newSession(in: model.selectedFolderForNewItems) }
                .keyboardShortcut("n")
            Button(L("New Folder…")) { model.requestNewFolder(parent: model.selectedFolderForNewItems) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L("New Local Terminal")) { model.openLocalTerminal() }
                .keyboardShortcut("t")
        }

        // Replaces the system "Close" item: in a tabbed window ⌘W closes a tab.
        CommandGroup(replacing: .saveItem) {
            Button(L("Close Tab")) { model.closeSelectedTabOrWindow() }
                .keyboardShortcut("w")
            Button(L("Close Other Tabs")) {
                if let id = model.selectedTabID { model.closeOtherTabs(id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(model.tabs.count < 2)
            Button(L("Close Window")) { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            // Sends "saveDocument:" (NSDocument.save(_:) in Swift); remote editor windows handle it.
            Button(L("Save")) { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
                .keyboardShortcut("s")
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button(model.sidebarMode == .files ? L("Show Sessions") : L("Show SFTP Browser")) {
                model.sidebarMode = model.sidebarMode == .files ? .sessions : .files
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Button(model.monitorEnabled ? L("Hide Status Bar") : L("Show Status Bar")) {
                model.monitorEnabled.toggle()
            }
            .keyboardShortcut("/")
            Divider()
            Button(L("Bigger Text")) { model.adjustFontSize(by: 1) }
                .keyboardShortcut("+")
            Button(L("Smaller Text")) { model.adjustFontSize(by: -1) }
                .keyboardShortcut("-")
            Button(L("Actual Size")) { model.resetFontSize() }
                .keyboardShortcut("0")
        }

        CommandMenu(L("Session")) {
            sessionItems
            Divider()
            Button(model.selectedTab?.isLocal == true ? L("Restart Shell") : L("Reconnect")) { model.reconnectSelectedTab() }
                .keyboardShortcut("r")
                .disabled(model.selectedTab == nil || model.selectedTab?.state.isActive == true)
            Button(L("Duplicate Tab")) {
                if let id = model.selectedTabID { model.duplicateTab(id) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.selectedTab == nil)
        }

        CommandMenu("SFTP") {
            fileItems
        }

        // Tab navigation belongs to the Window menu.
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button(L("Show Previous Tab")) { model.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.tabs.count < 2)
            Button(L("Show Next Tab")) { model.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.tabs.count < 2)
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? L("Show Last Tab") : L("Show Tab %@", number)) { model.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(model.tabs.isEmpty)
            }
        }

        CommandGroup(replacing: .help) {
            Button(L("AbobaXTerm Website")) { NSWorkspace.shared.open(AboutPanel.website) }
        }
    }

    /// Commands for the session or folder selected in the sidebar.
    @ViewBuilder
    private var sessionItems: some View {
        let sessionID = model.sidebarSelection?.sessionID
        let session = sessionID.flatMap { model.library.session(id: $0) }
        let folderID: UUID? = if case .folder(let id) = model.sidebarSelection { id } else { nil }

        Button(L("Connect")) { model.connectSelection() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(sessionID == nil)
        Button(L("Edit Session…")) {
            if let sessionID { model.editSession(sessionID) }
        }
        .keyboardShortcut("e")
        .disabled(sessionID == nil)
        Button(L("Duplicate Session")) {
            if let sessionID { model.duplicateSession(sessionID) }
        }
        .disabled(sessionID == nil)
        // The title says what will happen, as in the context menu.
        Button(session?.isFavorite == true ? L("Remove from Favorites") : L("Add to Favorites")) {
            if let sessionID { model.toggleFavorite(sessionID) }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(sessionID == nil)
        Button(L("Copy SSH Command")) {
            if let sessionID { model.copyCommandLine(sessionID) }
        }
        .disabled(sessionID == nil)
        Divider()
        Button(L("Rename Folder…")) {
            if let folderID { model.requestRenameFolder(folderID) }
        }
        .disabled(folderID == nil)
        Button(L("Delete…")) {
            if let sessionID { model.requestDeleteSession(sessionID) } else if let folderID { model.requestDeleteFolder(folderID) }
        }
        .keyboardShortcut(.delete)
        .disabled(sessionID == nil && folderID == nil)
    }

    /// Commands for the SFTP browser of the selected tab.
    @ViewBuilder
    private var fileItems: some View {
        let browser = model.selectedFileBrowser
        let ready = browser?.status == .ready

        Button(L("Home Folder")) { browser?.goHome() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!ready)
        Button(L("Refresh")) { browser?.refresh() }
            .disabled(!ready)
        Button(L("Find in This Folder")) {
            model.sidebarMode = .files
            browser?.toggleSearch()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(!ready)
        Divider()
        Button(L("Upload…")) {
            if let browser { FileUploadPanel.choose(for: browser) }
        }
        .disabled(!ready)
        Button(L("New Folder…")) { browser?.requestNewFolder(in: nil) }
            .disabled(!ready)
        Button(L("New File…")) { browser?.requestNewFile(in: nil) }
            .disabled(!ready)
        Divider()
        Button(L("Copy Current Path")) { browser?.copyCurrentPath() }
            .disabled(!ready)
        Button(browser?.showHidden == true ? L("Hide Hidden Files") : L("Show Hidden Files")) {
            browser?.showHidden.toggle()
        }
        .disabled(browser == nil)
    }
}

/// The standard About window, with the credit line that used to sit in Settings.
@MainActor
enum AboutPanel {
    static let website = URL(string: "https://abobaxterm.site")!

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(string: "Prod by xa1ven | Mike Dubenskov\n", attributes: base)
        var link = base
        link[.link] = website
        credits.append(NSAttributedString(string: website.host ?? "", attributes: link))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

/// "Upload…" from the menu bar: files and folders go to the current remote folder.
@MainActor
enum FileUploadPanel {
    static func choose(for browser: FileBrowserModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Upload")
        panel.message = L("Upload to %@", browser.currentPath)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { browser.upload(urls, to: nil) }
        }
        if let window = NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
