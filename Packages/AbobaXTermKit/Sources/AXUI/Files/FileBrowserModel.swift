import AXL10n
import AppKit
import AXModels
import AXSFTP
import AXSSH
import AXTerminal
import Observation

/// A row in the remote file outline. Reference type: NSOutlineView items.
@MainActor
final class FileNode {
    let info: SFTPFileInfo
    /// nil until the directory has been listed.
    var children: [FileNode]?
    /// The ".." row at the top of the list.
    let isParentLink: Bool

    init(info: SFTPFileInfo, isParentLink: Bool = false) {
        self.info = info
        self.isParentLink = isParentLink
    }

    var path: String { info.path }
    var isDirectory: Bool { info.isDirectory }
}

/// Implemented by the outline: expands the folders leading to a path and selects it.
@MainActor
protocol FileRevealing: AnyObject {
    func reveal(_ path: String, under root: String) async
    /// Collapses folders opened by previous reveals.
    func clearRevealed()
}

/// Requests shown as alerts by the panel.
struct FileNameRequest: Identifiable {
    enum Kind { case newFolder(in: String), newFile(in: String), rename(String) }
    let id = UUID()
    var kind: Kind
    var name: String

    var title: String {
        switch kind {
        case .newFolder: L("New Folder")
        case .newFile: L("New File")
        case .rename: L("Rename")
        }
    }
}

struct FileDeleteRequest: Identifiable {
    let id = UUID()
    let items: [SFTPFileInfo]
}

struct FileOverwriteRequest: Identifiable {
    let id = UUID()
    let names: [String]
    let perform: @MainActor () -> Void
}

/// SFTP file browser state for one SSH tab. The SFTP channel runs over the
/// tab's ControlMaster connection, so it never authenticates on its own.
@MainActor
@Observable
public final class FileBrowserModel {
    public enum Status: Equatable {
        case waiting, connecting, ready
        case failed(String)
    }

    public private(set) var status: Status = .waiting
    public private(set) var currentPath = ""
    public private(set) var homePath = ""
    public private(set) var isLoading = false
    /// Bumped whenever the outline must reload.
    private(set) var generation = 0
    var showHidden: Bool {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: Self.showHiddenKey)
            refresh()
        }
    }

    var nameRequest: FileNameRequest?
    var deleteRequest: FileDeleteRequest?
    var overwriteRequest: FileOverwriteRequest?
    var errorText: String?

    public let transfers = TransferQueue()

    @ObservationIgnored private(set) var rootNodes: [FileNode] = []
    @ObservationIgnored var expandedPaths: Set<String> = []
    @ObservationIgnored private(set) var client: SFTPClient?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private weak var tab: TerminalTab?
    @ObservationIgnored private let builder: SSHCommandBuilder
    /// The outline view, which can expand folders and select a path.
    @ObservationIgnored weak var revealer: FileRevealing?

    // Search (recursive `find` below the folder it was started in).
    var isSearchVisible = false
    var searchText = ""
    private(set) var searchResults: [String] = []
    private(set) var searchIndex: Int?
    private(set) var isSearching = false
    private(set) var searchMessage: String?
    @ObservationIgnored private var searchedKey: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    static let searchLimit = 500

    private static let showHiddenKey = "fileBrowserShowHidden"

    public init(tab: TerminalTab, builder: SSHCommandBuilder) {
        self.tab = tab
        self.builder = builder
        self.showHidden = UserDefaults.standard.object(forKey: Self.showHiddenKey) as? Bool ?? true
        transfers.clientProvider = { [weak self] in self?.client }
        observeTerminal()
    }

    /// Follows the tab's state even while the panel is not on screen, so the
    /// browser is ready when the user switches to it.
    private func observeTerminal() {
        guard let tab else { return }
        withObservationTracking {
            _ = tab.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncWithTerminal()
                self?.observeTerminal()
            }
        }
    }

    var session: Session? { tab?.session }
    var hostLabel: String { session?.displayName ?? "" }

    // MARK: Connection

    /// Called whenever the terminal state changes.
    func syncWithTerminal() {
        guard let tab else { return }
        if tab.state.isActive {
            if client == nil || client?.isClosed == true { connect() }
        } else if client == nil {
            connectTask?.cancel()
            connectTask = nil
            if case .failed = status {} else { status = .waiting }
        }
    }

    func connect() {
        guard connectTask == nil else { return }
        connectTask = Task { [weak self] in
            await self?.runConnect()
            self?.connectTask = nil
        }
    }

    private func runConnect() async {
        guard let session else { return }
        client?.close()
        client = nil
        status = .waiting

        // Wait for the terminal's ssh to finish authenticating and bring the
        // master up; the SFTP channel then needs no authentication at all.
        var attempt = 0
        while !(await ControlMasterManager.isMasterRunning(session, builder: builder)) {
            guard !Task.isCancelled else { return }
            guard tab?.state.isActive == true else {
                status = .waiting
                return
            }
            attempt += 1
            try? await Task.sleep(for: .milliseconds(attempt < 40 ? 250 : 1000))
        }

        status = .connecting
        do {
            let args = try builder.muxArguments(for: session, subsystem: "sftp")
            let client = try await SFTPClient.connect(executable: builder.sshPath, arguments: args)
            guard !Task.isCancelled else {
                client.close()
                return
            }
            self.client = client
            homePath = try await client.realPath(".")
            status = .ready
            await load(currentPath.isEmpty ? homePath : currentPath)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        transfers.cancelAll()
        client?.close()
        client = nil
    }

    // MARK: Navigation

    func open(_ path: String) {
        Task { await load(path) }
    }

    func goUp() {
        guard currentPath != "/" else { return }
        open(SFTPClient.parent(of: currentPath))
    }

    func goHome() {
        open(homePath.isEmpty ? "." : homePath)
    }

    func refresh() {
        guard !currentPath.isEmpty else { return }
        Task { await load(currentPath, keepExpansion: true) }
    }

    func copyCurrentPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentPath, forType: .string)
    }

    private func load(_ path: String, keepExpansion: Bool = false) async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let resolved = try await client.realPath(path)
            let attrs = try await client.attributes(resolved)
            guard attrs.isDirectory else {
                errorText = L("“%@” is not a folder.", resolved)
                return
            }
            let entries = try await client.list(resolved)
            if !keepExpansion { expandedPaths = [] }
            var nodes = makeNodes(entries)
            // Preload expanded folders so the outline can restore them.
            for node in nodes where expandedPaths.contains(node.path) {
                await preload(node, client: client)
            }
            if resolved != "/" {
                nodes.insert(FileNode(info: SFTPFileInfo(name: "..", path: SFTPClient.parent(of: resolved),
                                                         attributes: SFTPAttributes(permissions: 0o040755)),
                                      isParentLink: true), at: 0)
            }
            if resolved != currentPath { resetSearchResults() }
            currentPath = resolved
            rootNodes = nodes
            generation += 1
        } catch {
            handle(error)
        }
    }

    private func preload(_ node: FileNode, client: SFTPClient) async {
        guard let entries = try? await client.list(node.path) else {
            expandedPaths.remove(node.path)
            return
        }
        node.children = makeNodes(entries)
        for child in node.children ?? [] where expandedPaths.contains(child.path) {
            await preload(child, client: client)
        }
    }

    /// Lists a folder's children for the outline (on expand).
    func loadChildren(of node: FileNode) async -> Bool {
        guard let client else { return false }
        do {
            node.children = makeNodes(try await client.list(node.path))
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func makeNodes(_ entries: [SFTPFileInfo]) -> [FileNode] {
        entries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .map { FileNode(info: $0) }
    }

    func handle(_ error: Error) {
        if let sftp = error as? SFTPError, sftp.status == .connectionLost || sftp.status == .noConnection {
            client = nil
            status = .failed(L("Connection lost"))
            if tab?.state.isActive == true { connect() }
            return
        }
        if error is CancellationError { return }
        errorText = error.localizedDescription
    }

    // MARK: Search

    func toggleSearch() {
        isSearchVisible.toggle()
        if !isSearchVisible { closeSearch() }
    }

    func closeSearch() {
        isSearchVisible = false
        searchTask?.cancel()
        resetSearchResults()
        revealer?.clearRevealed()
    }

    private func resetSearchResults() {
        searchTask?.cancel()
        searchResults = []
        searchIndex = nil
        searchMessage = nil
        searchedKey = nil
        isSearching = false
    }

    /// Return in the search field: search, or go to the next match if the
    /// query has not changed.
    func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if searchedKey == searchKey(query), !searchResults.isEmpty {
            showSearchResult(offset: 1)
        } else {
            runSearch(query)
        }
    }

    private func searchKey(_ query: String) -> String { "\(currentPath)\u{0}\(showHidden)\u{0}\(query)" }

    private func runSearch(_ query: String) {
        guard let session, client != nil else { return }
        resetSearchResults()
        revealer?.clearRevealed()
        isSearching = true
        let root = currentPath
        let key = searchKey(query)
        let includeHidden = showHidden
        let command = RemoteFind.command(root: root, query: query, limit: Self.searchLimit)
        let builder = builder
        searchTask = Task { [weak self] in
            do {
                let result = try await RemoteCommand.run(command, session: session, builder: builder)
                guard let self, !Task.isCancelled else { return }
                var paths = RemoteFind.parse(String(decoding: result.output, as: UTF8.self), root: root, includeHidden: includeHidden)
                let truncated = paths.count > Self.searchLimit
                if truncated { paths = Array(paths.prefix(Self.searchLimit)) }
                self.isSearching = false
                self.searchedKey = key
                self.searchResults = paths
                if paths.isEmpty {
                    self.searchMessage = L("No matches")
                } else {
                    self.searchMessage = truncated ? L("First %@ matches", Self.searchLimit) : nil
                    self.showSearchResult(index: 0)
                }
            } catch {
                guard let self, !(error is CancellationError) else { return }
                self.isSearching = false
                self.searchMessage = L("Search failed")
            }
        }
    }

    func showSearchResult(offset: Int) {
        guard !searchResults.isEmpty else { return }
        let current = searchIndex ?? -1
        showSearchResult(index: (current + offset + searchResults.count) % searchResults.count)
    }

    private func showSearchResult(index: Int) {
        searchIndex = index
        let path = searchResults[index]
        let root = currentPath
        Task { await revealer?.reveal(path, under: root) }
    }

    // MARK: File operations

    func requestNewFolder(in directory: String?) {
        nameRequest = FileNameRequest(kind: .newFolder(in: directory ?? currentPath), name: L("New Folder"))
    }

    func requestNewFile(in directory: String?) {
        nameRequest = FileNameRequest(kind: .newFile(in: directory ?? currentPath), name: "untitled.txt")
    }

    func requestRename(_ info: SFTPFileInfo) {
        nameRequest = FileNameRequest(kind: .rename(info.path), name: info.name)
    }

    func requestDelete(_ items: [SFTPFileInfo]) {
        guard !items.isEmpty else { return }
        deleteRequest = FileDeleteRequest(items: items)
    }

    func commitName(_ request: FileNameRequest) {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            errorText = L("“%@” is not a valid name.", name)
            return
        }
        guard let client else { return }
        Task {
            do {
                switch request.kind {
                case .newFolder(let directory):
                    try await client.makeDirectory(SFTPClient.join(directory, name))
                    expandedPaths.insert(directory)
                case .newFile(let directory):
                    try await client.createFile(SFTPClient.join(directory, name))
                    expandedPaths.insert(directory)
                case .rename(let path):
                    let target = SFTPClient.join(SFTPClient.parent(of: path), name)
                    guard target != path else { return }
                    if try await client.exists(target) {
                        errorText = L("“%@” already exists.", name)
                        return
                    }
                    try await client.rename(path, to: target)
                }
            } catch {
                handle(error)
            }
            refresh()
        }
    }

    func performDelete(_ request: FileDeleteRequest) {
        guard let client else { return }
        Task {
            for item in request.items {
                do {
                    try await client.removeRecursively(item.path)
                } catch {
                    handle(error)
                    break
                }
            }
            refresh()
        }
    }

    func copyPath(_ info: SFTPFileInfo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.path, forType: .string)
    }

    // MARK: Transfers

    /// Uploads local files/folders into `directory`, asking before replacing.
    func upload(_ urls: [URL], to directory: String?) {
        let directory = directory ?? currentPath
        guard let client, !urls.isEmpty else { return }
        Task { [weak self] in
            var existing: [String] = []
            for url in urls where (try? await client.exists(SFTPClient.join(directory, url.lastPathComponent))) == true {
                existing.append(url.lastPathComponent)
            }
            let start: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                for url in urls { self.enqueueUpload(url, to: SFTPClient.join(directory, url.lastPathComponent)) }
            }
            if existing.isEmpty {
                start()
            } else {
                self?.overwriteRequest = FileOverwriteRequest(names: existing, perform: start)
            }
        }
    }

    private func enqueueUpload(_ url: URL, to remotePath: String) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let measure: @Sendable (SFTPClient) async throws -> UInt64 = { _ in SFTPClient.localSize(of: url) }
        let work: @Sendable (SFTPClient, @escaping SFTPProgress) async throws -> Void = { client, progress in
            try await client.uploadItem(url, to: remotePath, progress: progress)
        }
        let completion: @MainActor (Error?) -> Void = { [weak self] error in
            if error == nil { self?.refreshSoon() }
        }
        let item = TransferItem(
            name: url.lastPathComponent, direction: .upload,
            totalBytes: isDirectory ? nil : SFTPClient.localSize(of: url),
            measure: isDirectory ? measure : nil, work: work, completion: completion)
        transfers.enqueue(item)
    }

    /// Downloads into a local folder; picks "name 2" if the name is taken.
    func download(_ items: [SFTPFileInfo], to folder: URL) {
        for info in items {
            enqueueDownload(info, to: Self.uniqueURL(in: folder, name: info.name), completion: nil)
        }
    }

    func enqueueDownload(_ info: SFTPFileInfo, to localURL: URL, completion: (@MainActor (Error?) -> Void)?) {
        let path = info.path
        let measure: @Sendable (SFTPClient) async throws -> UInt64 = { client in try await client.totalSize(of: path) }
        let work: @Sendable (SFTPClient, @escaping SFTPProgress) async throws -> Void = { client, progress in
            try await client.downloadItem(path, to: localURL, progress: progress)
        }
        let item = TransferItem(
            name: info.name, direction: .download,
            totalBytes: info.isDirectory ? nil : info.size,
            measure: info.isDirectory ? measure : nil, work: work, completion: completion)
        transfers.enqueue(item)
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty || base.isEmpty ? "\(name) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Coalesces refreshes after a burst of finished uploads.
    private func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: Editor

    func openInEditor(_ info: SFTPFileInfo) {
        RemoteEditorWindowController.open(path: info.path, browser: self)
    }
}
