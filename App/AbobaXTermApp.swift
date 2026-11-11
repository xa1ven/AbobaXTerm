import AppKit
import AXUI
import SwiftUI

@main
struct AbobaXTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("AbobaXTerm", id: "main") {
            MainView()
                .environment(AppDelegate.model)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            SidebarCommands()
            AppCommands(model: AppDelegate.model)
        }

        Settings {
            SettingsView()
                .environment(AppDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = AppModel(
        askpassHelperPath: Bundle.main.url(forAuxiliaryExecutable: "abx-askpass")?.path
    )

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = Self.model.activeConnectionCount
        let unsaved = Self.model.hasUnsavedWork
        guard active > 0 || unsaved else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit AbobaXTerm?"
        var lines: [String] = []
        if active > 0 {
            lines.append(active == 1 ? "1 connection is open and will be closed."
                                     : "\(active) connections are open and will be closed.")
        }
        if unsaved {
            lines.append("Unsaved remote files or running transfers will be lost.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
