import SwiftUI

/// Menu bar commands and keyboard shortcuts.
public struct AppCommands: Commands {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { model.newSession(in: model.selectedFolderForNewItems) }
                .keyboardShortcut("n")
            Button("New Folder") { model.requestNewFolder(parent: model.selectedFolderForNewItems) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Local Terminal") { model.openLocalTerminal() }
                .keyboardShortcut("t")
            Divider()
            // Sends "saveDocument:" (NSDocument.save(_:) in Swift); remote editor windows handle it.
            Button("Save") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
                .keyboardShortcut("s")
            Divider()
            // Placed before the system "Close" item so ⌘W closes a tab first.
            Button("Close Tab") { model.closeSelectedTabOrWindow() }
                .keyboardShortcut("w")
        }

        CommandMenu("Session") {
            Button("Connect") { model.connectSelection() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.sidebarSelection?.sessionID == nil)
            Button("Edit Session…") {
                if let id = model.sidebarSelection?.sessionID { model.editSession(id) }
            }
            .keyboardShortcut("e")
            .disabled(model.sidebarSelection?.sessionID == nil)
            Button("Toggle Favorite") {
                if let id = model.sidebarSelection?.sessionID { model.toggleFavorite(id) }
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(model.sidebarSelection?.sessionID == nil)

            Divider()

            Button(model.selectedTab?.isLocal == true ? "Restart Shell" : "Reconnect") { model.reconnectSelectedTab() }
                .keyboardShortcut("r")
                .disabled(model.selectedTab == nil || model.selectedTab?.state.isActive == true)
            Button("Duplicate Tab") {
                if let id = model.selectedTabID { model.duplicateTab(id) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.selectedTab == nil)

            Divider()

            Button("Show Next Tab") { model.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { model.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Show Last Tab" : "Show Tab \(number)") { model.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button(model.sidebarMode == .files ? "Show Sessions" : "Show SFTP Browser") {
                model.sidebarMode = model.sidebarMode == .files ? .sessions : .files
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Bigger Text") { model.adjustFontSize(by: 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { model.adjustFontSize(by: -1) }
                .keyboardShortcut("-")
            Button("Actual Size") { model.resetFontSize() }
                .keyboardShortcut("0")
        }
    }
}
