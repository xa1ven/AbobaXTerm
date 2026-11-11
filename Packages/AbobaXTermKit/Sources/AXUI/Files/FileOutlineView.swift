import AppKit
import AXSFTP
import SwiftUI
import UniformTypeIdentifiers

/// The remote file list: an NSOutlineView (lazy folder expansion, multi-select,
/// file-promise drag to Finder, file drops from Finder, context menu).
struct FileOutlineView: NSViewRepresentable {
    let model: FileBrowserModel
    /// Read in the parent's body so SwiftUI updates us when it changes.
    let generation: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileOutline()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask([], forLocal: true)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.keyHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handleKey(event) ?? false
        }
        context.coordinator.outline = outline
        model.revealer = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.reloadIfNeeded(generation: generation)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate,
        FileRevealing {
        let model: FileBrowserModel
        weak var outline: FileOutline?
        private var shownGeneration = -1
        /// Folders expanded by search reveals (collapsed again on the next one).
        private var revealedFolders: [String] = []
        nonisolated private static let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            return q
        }()

        init(model: FileBrowserModel) {
            self.model = model
        }

        func reloadIfNeeded(generation: Int) {
            guard let outline, generation != shownGeneration else { return }
            shownGeneration = generation
            let selected = Set(selectedNodes().map(\.path))
            outline.reloadData()
            restoreExpansion(model.rootNodes)
            let rows = IndexSet((0..<outline.numberOfRows).filter {
                guard let node = outline.item(atRow: $0) as? FileNode else { return false }
                return !node.isParentLink && selected.contains(node.path)
            })
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }

        private func restoreExpansion(_ nodes: [FileNode]) {
            for node in nodes where node.children != nil && model.expandedPaths.contains(node.path) {
                outline?.expandItem(node)
                restoreExpansion(node.children ?? [])
            }
        }

        // MARK: Selection helpers

        func selectedNodes() -> [FileNode] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
        }

        /// Nodes a context-menu action applies to: the selection if the
        /// clicked row is part of it, otherwise just the clicked row
        /// (nothing for empty space and "..").
        private func targetNodes() -> [FileNode] {
            guard let outline else { return [] }
            let clicked = outline.clickedRow
            if clicked >= 0 {
                if outline.selectedRowIndexes.contains(clicked) { return selectedNodes().filter { !$0.isParentLink } }
                if let node = outline.item(atRow: clicked) as? FileNode, !node.isParentLink { return [node] }
                return []
            }
            // Right-click on empty space: actions for the current folder.
            return []
        }

        private func clickedNode() -> FileNode? {
            guard let outline, outline.clickedRow >= 0 else { return nil }
            return outline.item(atRow: outline.clickedRow) as? FileNode
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FileNode else { return model.rootNodes.count }
            return node.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FileNode else { return model.rootNodes[index] }
            return node.children![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileNode else { return false }
            return node.isDirectory && !node.isParentLink
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileNode else { return false }
            if node.children != nil { return true }
            // Load first, then expand.
            Task { [weak self, weak outlineView] in
                guard let self, await self.model.loadChildren(of: node) else { return }
                outlineView?.reloadItem(node, reloadChildren: true)
                outlineView?.expandItem(node)
            }
            return false
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? FileNode { model.expandedPaths.insert(node.path) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? FileNode {
                model.expandedPaths.remove(node.path)
                // Re-list on the next expand so it is fresh.
                node.children = nil
            }
        }

        // MARK: Cells

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            let cell = outlineView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView ?? FileCellView()
            cell.configure(with: node)
            return cell
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: Any?) {
            guard let node = clickedNode() else { return }
            activate(node)
        }

        private func activate(_ node: FileNode) {
            if node.isParentLink {
                model.goUp()
            } else if node.isDirectory {
                model.open(node.path)
            } else {
                model.openInEditor(node.info)
            }
        }

        func handleKey(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (event.keyCode, flags) {
            case (36, []), (76, []), (125, .command): // Return, Enter, ⌘↓
                if let node = selectedNodes().first { activate(node) }
                return true
            case (126, .command): // ⌘↑
                model.goUp()
                return true
            case (51, .command), (117, []): // ⌘⌫, forward delete
                model.requestDelete(selectedNodes().filter { !$0.isParentLink }.map(\.info))
                return true
            default:
                return false
            }
        }

        // MARK: Context menu

        /// Empty space (or ".."): actions for the current folder.
        /// A file: its own actions. A folder: its actions plus upload/create inside it.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let targets = targetNodes()
            let refresh = ClosureMenuItem("Refresh") { [model] in model.refresh() }

            guard !targets.isEmpty else {
                let folder = model.currentPath
                menu.addItem(ClosureMenuItem("Upload…") { [weak self] in self?.chooseUpload(to: folder) })
                menu.addItem(ClosureMenuItem("New Folder…") { [model] in model.requestNewFolder(in: folder) })
                menu.addItem(ClosureMenuItem("New File…") { [model] in model.requestNewFile(in: folder) })
                menu.addItem(.separator())
                menu.addItem(refresh)
                return
            }

            let infos = targets.map(\.info)
            guard targets.count == 1, let node = targets.first else {
                menu.addItem(ClosureMenuItem("Download \(targets.count) Items…") { [weak self] in self?.chooseDownloadFolder(for: infos) })
                menu.addItem(ClosureMenuItem("Delete \(targets.count) Items…") { [model] in model.requestDelete(infos) })
                menu.addItem(.separator())
                menu.addItem(refresh)
                return
            }

            let info = node.info
            if node.isDirectory {
                menu.addItem(ClosureMenuItem("Open") { [model] in model.open(info.path) })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Upload Here…") { [weak self] in self?.chooseUpload(to: info.path) })
                menu.addItem(ClosureMenuItem("New Folder Inside…") { [model] in model.requestNewFolder(in: info.path) })
                menu.addItem(ClosureMenuItem("New File Inside…") { [model] in model.requestNewFile(in: info.path) })
            } else {
                menu.addItem(ClosureMenuItem("Open in Editor") { [model] in model.openInEditor(info) })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Rename…") { [model] in model.requestRename(info) })
            menu.addItem(ClosureMenuItem("Download…") { [weak self] in self?.chooseDownloadFolder(for: infos) })
            menu.addItem(ClosureMenuItem("Delete…") { [model] in model.requestDelete(infos) })
            menu.addItem(ClosureMenuItem("Copy Path") { [model] in model.copyPath(info) })
            menu.addItem(.separator())
            menu.addItem(refresh)
        }

        // MARK: Reveal (search)

        func reveal(_ path: String, under root: String) async {
            guard let outline else { return }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix) else { return }
            let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)

            // Fold away what the previous match opened, unless it leads here too.
            for folder in revealedFolders.reversed() where !path.hasPrefix(folder + "/") {
                if let node = node(atPath: folder) { outline.collapseItem(node) }
            }
            revealedFolders.removeAll { !path.hasPrefix($0 + "/") }

            var siblings = model.rootNodes
            for (index, name) in components.enumerated() {
                guard let node = siblings.first(where: { !$0.isParentLink && $0.info.name == name }) else { return }
                if index == components.count - 1 {
                    let row = outline.row(forItem: node)
                    guard row >= 0 else { return }
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                    return
                }
                if node.children == nil {
                    guard await model.loadChildren(of: node) else { return }
                    outline.reloadItem(node, reloadChildren: true)
                }
                if !outline.isItemExpanded(node) {
                    outline.expandItem(node)
                    revealedFolders.append(node.path)
                }
                siblings = node.children ?? []
            }
        }

        func clearRevealed() {
            guard let outline else { return }
            for folder in revealedFolders.reversed() {
                if let node = node(atPath: folder) { outline.collapseItem(node) }
            }
            revealedFolders = []
        }

        private func node(atPath path: String) -> FileNode? {
            guard let outline else { return nil }
            for row in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: row) as? FileNode, !node.isParentLink, node.path == path { return node }
            }
            return nil
        }

        func chooseDownloadFolder(for infos: [SFTPFileInfo]) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Download"
            panel.message = "Choose a folder to download to"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard let window = outline?.window else { return }
            panel.beginSheetModal(for: window) { [model] response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { model.download(infos, to: url) }
            }
        }

        func chooseUpload(to directory: String) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = "Upload"
            panel.message = "Upload to \(directory)"
            guard let window = outline?.window else { return }
            panel.beginSheetModal(for: window) { [model] response in
                guard response == .OK else { return }
                let urls = panel.urls
                MainActor.assumeIsolated { model.upload(urls, to: directory) }
            }
        }

        // MARK: Drag out (file promises)

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = item as? FileNode, !node.isParentLink else { return nil }
            let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: (node.info.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = node.info
            return provider
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (provider.userInfo as? SFTPFileInfo)?.name ?? "file"
        }

        nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
            Self.promiseQueue
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                             completionHandler: @escaping (Error?) -> Void) {
            guard let info = provider.userInfo as? SFTPFileInfo else {
                completionHandler(CocoaError(.fileWriteUnknown))
                return
            }
            let done = UncheckedSendable(completionHandler)
            // Finder waits for the completion; the transfer itself shows in the queue.
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor [model] in
                model.enqueueDownload(info, to: url) { error in
                    done.value(error)
                    semaphore.signal()
                }
            }
            semaphore.wait()
        }

        // MARK: Drop in (from Finder)

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            if let source = info.draggingSource as? NSView, source === outlineView { return [] }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            if let node = item as? FileNode, node.isDirectory {
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else if let node = item as? FileNode, let parent = outlineView.parent(forItem: node) {
                outlineView.setDropItem(parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else {
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            return .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            model.upload(urls, to: (item as? FileNode)?.path)
            return true
        }
    }
}

/// Outline view with a few keyboard shortcuts.
final class FileOutline: NSOutlineView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Icon, name and size.
final class FileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private static var iconCache: [String: NSImage] = [:]

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = nameLabel
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right
        for view in [icon, nameLabel, detailLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(with node: FileNode) {
        let info = node.info
        nameLabel.stringValue = info.name
        nameLabel.textColor = info.name.hasPrefix(".") && !node.isParentLink ? .secondaryLabelColor : .labelColor
        icon.image = Self.icon(for: node)
        detailLabel.stringValue = node.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file)
        if node.isParentLink {
            toolTip = "Parent folder"
        } else {
            var lines = [info.name]
            if info.isSymlink { lines.append("Symbolic link") }
            if !node.isDirectory { lines.append(ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file)) }
            if let date = info.attributes.modificationDate {
                lines.append("Modified " + date.formatted(date: .abbreviated, time: .shortened))
            }
            let perms = info.attributes.permissionString
            if !perms.isEmpty { lines.append(perms + (info.attributes.uid.map { "  uid \($0)" } ?? "")) }
            toolTip = lines.joined(separator: "\n")
        }
    }

    private static func icon(for node: FileNode) -> NSImage {
        if node.isParentLink {
            return NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Parent folder") ?? NSImage()
        }
        let ext = (node.info.name as NSString).pathExtension.lowercased()
        let key = node.isDirectory ? (node.info.isSymlink ? "/link" : "/") : (node.info.isSymlink ? "link." : "") + ext
        if let cached = iconCache[key] { return cached }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
