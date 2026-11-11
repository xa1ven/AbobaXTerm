#if DEBUG
import AppKit
import AXModels
import AXSFTP

/// Fixed id so the debug master socket ("cm-d0d0d0d0-…") is easy to find and close.
private let debugSessionID = UUID(uuidString: "D0D0D0D0-0000-0000-0000-000000000001")!

/// Debug-only: renders the app's own windows to PNG files, so layout can be
/// checked without screen-recording permission.
///
///   ABX_SNAPSHOT_DIR=/tmp/shots ABX_SNAPSHOT_STEPS=home,local,editor-auth \
///     AbobaXTerm.app/Contents/MacOS/AbobaXTerm
///
/// Steps: home, local, editor, editor-auth, editor-advanced, editor-org,
/// settings, dark, light (dark/light change the saved preference). The app exits after the last step.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ model: AppModel, openSettings: @escaping () -> Void) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ABX_SNAPSHOT_DIR"] else { return }
        let steps = (env["ABX_SNAPSHOT_STEPS"] ?? "home").split(separator: ",").map(String.init)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            // In-process only (the saved preference is untouched): glass renders
            // white in snapshots, so dark-mode text would be invisible.
            if env["ABX_SNAPSHOT_LIGHT"] != nil { NSApp.appearance = NSAppearance(named: .aqua) }
            for (index, step) in steps.enumerated() {
                if step == "settings" { openSettings() } else { perform(step, model) }
                try? await Task.sleep(for: .seconds(step == "settings" ? 3 : step.hasPrefix("sftp") ? 4 : 1.5))
                for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
                capture(into: dir, prefix: String(format: "%02d-%@", index, step))
                captureSidebar(into: dir, prefix: String(format: "%02d-%@", index, step), model: model)
                if step.hasPrefix("editor") {
                    model.editorRequest = nil
                    try? await Task.sleep(for: .seconds(0.6))
                }
            }
            // Not shutdown(): it would also close ssh masters of another running instance.
            for tab in model.tabs { model.closeTab(tab.id) }
            exit(0)
        }
    }

    private static func perform(_ step: String, _ model: AppModel) {
        func editor(_ section: EditorSection?) {
            model.editorRequest = EditorRequest(session: Session(), isNew: true, initialSection: section)
        }
        switch step {
        case "local": model.openLocalTerminal()
        case "highlight":
            model.openLocalTerminal()
            let sample = """
            clear; cat <<'ABX'
            Last login: Wed Nov 11 00:33:16 2026 from 147.45.178.199
            To see these additional updates run: apt list --upgradable
            Learn more at https://ubuntu.com/esm
            tcp   LISTEN 0  128   127.0.0.1:6010   0.0.0.0:*   users:(("sshd",pid=72684,fd=7))
            tcp   LISTEN 0  128       [::1]:6010      [::]:*
                 Active: active (running) since Thu 2026-11-05 06:22:17 EET; 5 days ago
                 Loaded: loaded (/usr/lib/systemd/system/ssh.service; disabled; preset: enabled)
            Nov 11 00:41:35 host sshd[72679]: Invalid user admin from 2.57.122.209 port 43406
            Nov 11 00:41:35 host sshd[72679]: Connection closed by invalid user admin 2.57.122.209 port 43406 [preauth]
            Nov 11 00:43:37 host sshd[72684]: Accepted publickey for root from 147.45.178.199 port 60792
            Nov 11 00:43:37 host sshd[72684]: pam_unix(sshd:session): session opened for user root(uid=0)
            curl: (7) Failed to connect: Connection refused; warning: retrying, error count 3
            ABX

            """
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                model.selectedTab?.terminalView.send(txt: sample)
            }
        case "editor": editor(nil)
        case "editor-auth": editor(.authentication)
        case "editor-advanced": editor(.advanced)
        case "editor-org": editor(.organization)
        case "views":
            func walk(_ v: NSView, _ depth: Int) {
                if v is NSTableView || v is NSScrollView {
                    FileHandle.standardError.write(Data("VIEW \(depth) \(type(of: v)) table=\(v is NSTableView) outline=\(v is NSOutlineView)\n".utf8))
                }
                v.subviews.forEach { walk($0, depth + 1) }
            }
            for w in NSApp.windows where w.isVisible { if let c = w.contentView { walk(c, 0) } }
        case "x11":
            // Same as "sftp" with X11 forwarding; then starts xeyes on the "server".
            let env = ProcessInfo.processInfo.environment
            let parts = (env["ABX_SNAPSHOT_SSH"] ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return }
            let session = Session(id: debugSessionID, name: "Debug X11", host: parts[0], port: Int(parts[1]),
                                  auth: .publicKey(path: parts[2]), extraOptions: parts[3], x11Forwarding: true)
            model.openTab(.ssh(session, isSaved: false))
            let command = env["ABX_SNAPSHOT_X11_CMD"] ?? "/opt/X11/bin/xeyes"
            Task { @MainActor in
                for _ in 0..<80 {
                    if model.selectedTab?.state == .running { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .seconds(2))
                model.selectedTab?.terminalView.send(txt: "echo DISPLAY=$DISPLAY; \(command) &\r")
            }
        case "wait":
            break
        case "sftp":
            // ABX_SNAPSHOT_SSH="host|port|keyPath|extra ssh options", ABX_SNAPSHOT_SFTP_DIR=/remote/dir
            let env = ProcessInfo.processInfo.environment
            let parts = (env["ABX_SNAPSHOT_SSH"] ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return }
            let session = Session(id: debugSessionID, name: "Debug sshd", host: parts[0], port: Int(parts[1]),
                                  auth: .publicKey(path: parts[2]), extraOptions: parts[3])
            model.openTab(.ssh(session, isSaved: false))
            Task { @MainActor in
                for _ in 0..<40 {
                    if let tab = model.selectedTab, let browser = model.fileBrowser(for: tab), browser.status == .ready {
                        if let dir = env["ABX_SNAPSHOT_SFTP_DIR"] { browser.open(dir) }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        case "sftp-upload":
            guard let tab = model.selectedTab, let browser = model.fileBrowser(for: tab),
                  let dir = ProcessInfo.processInfo.environment["ABX_SNAPSHOT_DIR"] else { return }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("upload-test.bin")
            try? Data(count: 40 * 1024 * 1024).write(to: url)
            browser.upload([url], to: nil)
        case "sftp-editor":
            guard let tab = model.selectedTab, let browser = model.fileBrowser(for: tab) else { return }
            let name = ProcessInfo.processInfo.environment["ABX_SNAPSHOT_EDIT_FILE"] ?? "file.txt"
            RemoteEditorWindowController.open(path: SFTPClient.join(browser.currentPath, name), browser: browser)
        case "sftp-search":
            guard let browser = model.selectedFileBrowser else { return }
            browser.isSearchVisible = true
            browser.searchText = ProcessInfo.processInfo.environment["ABX_SNAPSHOT_SEARCH"] ?? "*.conf"
            browser.submitSearch()
        case "sftp-search-next":
            model.selectedFileBrowser?.submitSearch()
        case "sftp-save", "sftp-conflict":
            guard let controller = RemoteEditorWindowController.open.values.first else { return }
            if step == "sftp-conflict" {
                // Simulate another user changing the file on the server.
                try? "changed elsewhere\n".write(toFile: controller.path, atomically: false, encoding: .utf8)
                let date = Date().addingTimeInterval(5)
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: controller.path)
            }
            let tv = controller.editor.textView
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.insertText("# \(step)\n", replacementRange: tv.selectedRange())
            controller.saveDocument(nil)
        case "dark": model.appearance = .dark
        case "light": model.appearance = .light
        default: break
        }
    }

    /// The glass sidebar does not draw in snapshots; capture the file outline
    /// (plain AppKit) and dump its rows as text instead.
    private static func captureSidebar(into dir: String, prefix: String, model: AppModel) {
        func findOutline(_ v: NSView) -> FileOutline? {
            if let o = v as? FileOutline { return o }
            for sub in v.subviews { if let o = findOutline(sub) { return o } }
            return nil
        }
        var lines = ["sidebarMode=\(model.sidebarMode)"]
        if let browser = model.selectedFileBrowser {
            lines.append("path=\(browser.currentPath) search=\(browser.isSearchVisible) results=\(browser.searchResults.count) index=\(browser.searchIndex.map(String.init) ?? "-") message=\(browser.searchMessage ?? "-")")
        }
        for window in NSApp.windows where window.isVisible {
            guard let root = window.contentView?.superview, let outline = findOutline(root) else { continue }
            for row in 0..<outline.numberOfRows {
                guard let node = outline.item(atRow: row) as? FileNode else { continue }
                let mark = outline.selectedRowIndexes.contains(row) ? "*" : " "
                let indent = String(repeating: "  ", count: outline.level(forRow: row))
                let expanded = outline.isItemExpanded(node) ? "v " : (node.isDirectory ? "> " : "  ")
                lines.append("\(mark) \(indent)\(expanded)\(node.info.name)")
            }
            if let view = outline.enclosingScrollView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-outline.png"))
            }
        }
        try? lines.joined(separator: "\n").write(toFile: dir + "/\(prefix)-state.txt", atomically: true, encoding: .utf8)
    }

    private static func capture(into dir: String, prefix: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.sheetParent != nil ? "sheet" : (window.title.isEmpty ? "window\(index)" : window.title)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
