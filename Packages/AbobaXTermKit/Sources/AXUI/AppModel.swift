import AXL10n
import AppKit
import AXModels
import AXSSH
import AXStorage
import AXTerminal
import AXX11
import Observation
import SwiftUI

/// Central app state: the session library, open tabs and pending UI requests.
@MainActor
@Observable
public final class AppModel {
    // MARK: Library

    public private(set) var library = SessionLibrary()
    public var searchText = "" {
        didSet {
            // Typing a session name shows the sessions list.
            if !searchText.isEmpty { sidebarMode = .sessions }
        }
    }
    /// Which tab of the sidebar is shown.
    public var sidebarMode: SidebarMode = .sessions
    public var sidebarSelection: SidebarItem?
    /// Folders shown open in the sidebar. Not saved: every launch starts with all folders closed.
    public var expandedFolders: Set<UUID> = []

    // MARK: Tabs

    public private(set) var tabs: [TerminalTab] = []
    public var selectedTabID: UUID? {
        didSet {
            guard selectedTabID != oldValue else { return }
            // SSH tabs show their files; local terminals and the home screen show sessions.
            sidebarMode = selectedTab.flatMap { fileBrowsers[$0.id] } != nil ? .files : .sessions
        }
    }

    public var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// SFTP browsers of SSH tabs, by tab id.
    public private(set) var fileBrowsers: [UUID: FileBrowserModel] = [:]

    /// Server statistics of SSH tabs, keyed by tab id.
    private(set) var monitors: [UUID: ServerMonitor] = [:]
    var sshBuilder: SSHCommandBuilder { launcher.builder }

    public func fileBrowser(for tab: TerminalTab) -> FileBrowserModel? {
        fileBrowsers[tab.id]
    }

    /// The selected tab's SFTP browser, if it is an SSH tab.
    public var selectedFileBrowser: FileBrowserModel? {
        selectedTab.flatMap { fileBrowsers[$0.id] }
    }

    // MARK: UI requests

    public var editorRequest: EditorRequest?
    public var deletionRequest: DeletionRequest?
    public var folderNameRequest: FolderNameRequest?
    public var errorMessage: ErrorMessage?
    /// X11 session opened while the built-in X server cannot be found: asks what to do.
    public var x11MissingRequest: Session?

    // MARK: Settings (persisted in UserDefaults)

    public private(set) var fontSize: CGFloat
    public var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            appearance.apply()
        }
    }
    /// Colors IPs, URLs and status words in plain terminal output.
    public var highlightOutput: Bool {
        didSet {
            UserDefaults.standard.set(highlightOutput, forKey: Self.highlightKey)
            for tab in tabs { tab.terminalView.highlighter.isEnabled = highlightOutput }
        }
    }
    /// Hold back pasted text of several lines in a small editor.
    public var confirmMultilinePaste: Bool {
        didSet {
            UserDefaults.standard.set(confirmMultilinePaste, forKey: Self.confirmPasteKey)
            applyPasteSettings()
        }
    }
    /// What to do with curly quotes, long dashes and the like in pasted text.
    public var pasteTypography: TypographyFix {
        didSet {
            UserDefaults.standard.set(pasteTypography.rawValue, forKey: Self.pasteTypographyKey)
            applyPasteSettings()
        }
    }
    /// Render X11 programs at Retina resolution (they are told to draw at 2x).
    public var x11HiDPI: Bool {
        didSet {
            UserDefaults.standard.set(x11HiDPI, forKey: Self.x11HiDPIKey)
            x11.prefersHiDPI = x11HiDPI
        }
    }
    /// Command+C/V/X/A/Z work as copy, paste, cut, select all and undo in X11 programs.
    public var x11CommandShortcuts: Bool {
        didSet {
            UserDefaults.standard.set(x11CommandShortcuts, forKey: Self.x11ShortcutsKey)
            x11.translatesCommandShortcuts = x11CommandShortcuts
        }
    }
    /// Summary of the session printed in the terminal when it connects.
    public var showSessionBanner: Bool {
        didSet {
            UserDefaults.standard.set(showSessionBanner, forKey: Self.bannerKey)
            rebuildLauncher()
        }
    }
    /// Card with shortcuts and facts about this Mac at the top of a local terminal.
    public var showLocalBanner: Bool {
        didSet {
            UserDefaults.standard.set(showLocalBanner, forKey: Self.localBannerKey)
            for tab in tabs where tab.isLocal { tab.localBanner = localBannerOptions }
        }
    }
    /// Status bar with live server statistics under SSH terminals.
    public var monitorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(monitorEnabled, forKey: Self.monitorEnabledKey)
            rebuildLauncher()
        }
    }
    /// Seconds between two readings of the server's counters.
    public var monitorInterval: Int {
        didSet { UserDefaults.standard.set(monitorInterval, forKey: Self.monitorIntervalKey) }
    }
    /// How long a master connection stays open after its last tab closes.
    public var controlPersistMinutes: Int {
        didSet {
            UserDefaults.standard.set(controlPersistMinutes, forKey: Self.controlPersistKey)
            rebuildLauncher()
        }
    }

    // MARK: Services

    @ObservationIgnored public let paths: AppPaths
    @ObservationIgnored let keychain = KeychainStore()
    @ObservationIgnored private let repository: SessionRepository
    @ObservationIgnored private(set) var launcher: SSHLauncher
    @ObservationIgnored private var broker: AskpassBroker?
    @ObservationIgnored private let askpassHelperPath: String?
    @ObservationIgnored private let askpassPresenter = AskpassPresenter()
    /// Built-in X server; starts with the first session that forwards X11.
    @ObservationIgnored public let x11: X11Service
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Master-socket prefixes of sessions opened by this app instance.
    @ObservationIgnored private var usedSocketPrefixes: Set<String> = []

    private static let fontSizeKey = "terminalFontSize"
    private static let appearanceKey = "appearance"
    private static let controlPersistKey = "controlPersistMinutes"
    private static let highlightKey = "highlightOutput"
    private static let bannerKey = "showSessionBanner"
    private static let localBannerKey = "showLocalBanner"
    private static let confirmPasteKey = "confirmMultilinePaste"
    private static let pasteTypographyKey = "pasteTypography"
    private static let x11HiDPIKey = "x11HiDPI"
    private static let x11ShortcutsKey = "x11CommandShortcuts"
    private static let monitorEnabledKey = "serverMonitorEnabled"
    private static let monitorIntervalKey = "serverMonitorInterval"
    public static let controlPersistChoices = [1, 5, 10, 30, 60]
    public static let monitorIntervalChoices = [1, 2, 5, 10]

    public init(paths: AppPaths = .standard, askpassHelperPath: String?) {
        self.paths = paths
        self.repository = SessionRepository(fileURL: paths.sessionsFile)
        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = stored > 0 ? stored : AXTerminalView.defaultFontSize
        self.appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "") ?? .system
        let storedPersist = UserDefaults.standard.integer(forKey: Self.controlPersistKey)
        let persistMinutes = storedPersist > 0 ? storedPersist : 10
        self.controlPersistMinutes = persistMinutes
        self.askpassHelperPath = askpassHelperPath
        self.highlightOutput = UserDefaults.standard.object(forKey: Self.highlightKey) as? Bool ?? true
        let monitorEnabled = UserDefaults.standard.object(forKey: Self.monitorEnabledKey) as? Bool ?? true
        self.monitorEnabled = monitorEnabled
        let showSessionBanner = UserDefaults.standard.object(forKey: Self.bannerKey) as? Bool ?? true
        self.showSessionBanner = showSessionBanner
        self.showLocalBanner = UserDefaults.standard.object(forKey: Self.localBannerKey) as? Bool ?? true
        self.confirmMultilinePaste = UserDefaults.standard.object(forKey: Self.confirmPasteKey) as? Bool ?? true
        self.pasteTypography = TypographyFix(rawValue: UserDefaults.standard.string(forKey: Self.pasteTypographyKey) ?? "") ?? .ask
        let storedInterval = UserDefaults.standard.integer(forKey: Self.monitorIntervalKey)
        self.monitorInterval = Self.monitorIntervalChoices.contains(storedInterval) ? storedInterval : 2

        let hiDPI = UserDefaults.standard.object(forKey: Self.x11HiDPIKey) as? Bool ?? true
        self.x11HiDPI = hiDPI
        let x11 = X11Service(runtimeDirectory: paths.runtimeDirectory)
        x11.prefersHiDPI = hiDPI
        let shortcuts = UserDefaults.standard.object(forKey: Self.x11ShortcutsKey) as? Bool ?? true
        self.x11CommandShortcuts = shortcuts
        x11.translatesCommandShortcuts = shortcuts
        self.x11 = x11
        let builder = SSHCommandBuilder(controlDirectory: paths.runtimeDirectory.path,
                                        controlPersistSeconds: persistMinutes * 60,
                                        xauthPath: X11Service.xauthLocation(runtimeDirectory: paths.runtimeDirectory))
        do {
            try paths.prepare()
            Self.removeStaleAskpassSockets(in: paths.runtimeDirectory)
            let presenter = askpassPresenter
            broker = try AskpassBroker(
                socketPath: paths.runtimeDirectory.appendingPathComponent("askpass-\(getpid()).sock").path,
                keychain: keychain,
                present: { question in await presenter.present(question) })
        } catch {
            // Without the broker ssh simply prompts inside the terminal.
            NSLog("AbobaXTerm: askpass disabled: \(error)")
        }
        launcher = SSHLauncher(builder: builder, broker: broker,
                               askpassHelperPath: broker == nil ? nil : askpassHelperPath,
                               x11: EmbeddedX11Display(service: x11),
                               banner: Self.bannerOptions(show: showSessionBanner, monitoring: monitorEnabled))
    }

    /// Deletes askpass sockets left behind by instances that crashed or were killed.
    private static func removeStaleAskpassSockets(in directory: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("askpass-") && name.hasSuffix(".sock") {
            let pidText = name.dropFirst("askpass-".count).dropLast(".sock".count)
            guard let pid = pid_t(pidText), pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    private var bannerOptions: BannerOptions? {
        Self.bannerOptions(show: showSessionBanner, monitoring: monitorEnabled)
    }

    private static func bannerOptions(show: Bool, monitoring: Bool) -> BannerOptions? {
        guard show else { return nil }
        return BannerOptions(appVersion: appVersion, monitoring: monitoring)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var localBannerOptions: LocalBannerOptions? {
        showLocalBanner ? LocalBannerOptions(appVersion: Self.appVersion) : nil
    }

    private func rebuildLauncher() {
        let builder = SSHCommandBuilder(controlDirectory: paths.runtimeDirectory.path,
                                        controlPersistSeconds: controlPersistMinutes * 60,
                                        xauthPath: X11Service.xauthLocation(runtimeDirectory: paths.runtimeDirectory))
        launcher = SSHLauncher(builder: builder, broker: broker,
                               askpassHelperPath: broker == nil ? nil : askpassHelperPath,
                               x11: EmbeddedX11Display(service: x11), banner: bannerOptions)
    }

    /// Loads the library; safe to call more than once.
    public func start() {
        guard !started else { return }
        started = true
        appearance.apply()
        do {
            library = try repository.load()
        } catch {
            errorMessage = ErrorMessage(title: L("Could not load sessions"), message: error.localizedDescription)
        }
    }

    /// Called from applicationWillTerminate.
    public func shutdown() {
        saveTask?.cancel()
        try? repository.save(library)
        for browser in fileBrowsers.values { browser.disconnect() }
        for tab in tabs { tab.close() }
        x11.shutdown()
        broker?.stop()
        ControlMasterManager.closeAll(in: paths.runtimeDirectory.path, socketPrefixes: usedSocketPrefixes,
                                      sshPath: launcher.builder.sshPath)
    }

    public var activeConnectionCount: Int {
        tabs.filter { $0.state.isActive }.count
    }

    /// Unsaved remote editor windows or running transfers (asked about on quit).
    public var hasUnsavedWork: Bool {
        RemoteEditorWindowController.hasUnsavedChanges || fileBrowsers.values.contains { $0.transfers.hasActive }
    }

    // MARK: Persistence

    private func mutate(_ body: (inout SessionLibrary) -> Void) {
        body(&library)
        scheduleSave()
    }

    /// Debounced, serialized save on a background thread.
    private func scheduleSave() {
        let previous = saveTask
        previous?.cancel()
        let snapshot = library
        let repository = repository
        saveTask = Task { [weak self] in
            await previous?.value
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try await Task.detached { try repository.save(snapshot) }.value
            } catch {
                self?.errorMessage = ErrorMessage(title: L("Could not save sessions"), message: error.localizedDescription)
            }
        }
    }

    // MARK: Sessions

    public func newSession(in folderID: UUID? = nil) {
        editorRequest = EditorRequest(session: Session(folderID: folderID), isNew: true)
    }

    public func editSession(_ id: UUID) {
        guard let session = library.session(id: id) else { return }
        editorRequest = EditorRequest(session: session, isNew: false)
    }

    /// Saves an edited session. `password` nil = keep the stored one.
    public func saveSession(_ session: Session, password: String?) {
        mutate { $0.upsert(session) }
        let account = KeychainStore.sessionAccount(session.id)
        do {
            if session.auth == .password {
                if let password, !password.isEmpty {
                    try keychain.setPassword(password, account: account, label: "AbobaXTerm: \(session.displayName)")
                }
            } else {
                try keychain.deletePassword(account: account)
            }
        } catch {
            errorMessage = ErrorMessage(title: L("Keychain error"), message: error.localizedDescription)
        }
        for tab in tabs where tab.session?.id == session.id {
            tab.updateSession(session)
        }
        sidebarSelection = .session(session.id)
    }

    public func hasSavedPassword(for sessionID: UUID) -> Bool {
        keychain.hasPassword(account: KeychainStore.sessionAccount(sessionID))
    }

    public func removeSavedPassword(for sessionID: UUID) {
        try? keychain.deletePassword(account: KeychainStore.sessionAccount(sessionID))
    }

    public func duplicateSession(_ id: UUID) {
        guard var copy = library.session(id: id) else { return }
        copy.id = UUID()
        copy.name = L("%@ copy", copy.displayName)
        copy.createdAt = Date()
        copy.lastConnectedAt = nil
        mutate { $0.upsert(copy) }
        sidebarSelection = .session(copy.id)
    }

    public func toggleFavorite(_ id: UUID) {
        mutate { lib in
            guard var s = lib.session(id: id) else { return }
            s.isFavorite.toggle()
            lib.upsert(s)
        }
    }

    public func move(sessionID: UUID, to folderID: UUID?) {
        mutate { $0.move(sessionID: sessionID, to: folderID) }
    }

    public func requestDeleteSession(_ id: UUID) {
        guard let session = library.session(id: id) else { return }
        deletionRequest = DeletionRequest(target: .session(id), name: session.displayName)
    }

    public func copyCommandLine(_ id: UUID) {
        guard let session = library.session(id: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(launcher.builder.commandLine(for: session), forType: .string)
    }

    public func commandLinePreview(for session: Session) -> String {
        launcher.builder.commandLine(for: session)
    }

    // MARK: Folders

    public func requestNewFolder(parent: UUID? = nil) {
        folderNameRequest = FolderNameRequest(mode: .create(parent: parent), name: L("New Folder"))
    }

    public func requestRenameFolder(_ id: UUID) {
        guard let folder = library.folder(id: id) else { return }
        folderNameRequest = FolderNameRequest(mode: .rename(id), name: folder.name)
    }

    public func commitFolderName(_ request: FolderNameRequest) {
        let name = request.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch request.mode {
        case .create(let parent):
            let folder = Folder(name: name, parentID: parent)
            mutate { $0.upsert(folder) }
            sidebarSelection = .folder(folder.id)
        case .rename(let id):
            mutate { lib in
                guard var folder = lib.folder(id: id) else { return }
                folder.name = name
                lib.upsert(folder)
            }
        }
    }

    public func move(folderID: UUID, to parentID: UUID?) {
        var lib = library
        guard lib.move(folderID: folderID, to: parentID) else { return }
        mutate { $0 = lib }
    }

    public func requestDeleteFolder(_ id: UUID) {
        guard let folder = library.folder(id: id) else { return }
        deletionRequest = DeletionRequest(target: .folder(id), name: folder.name)
    }

    public func performDeletion(_ request: DeletionRequest) {
        switch request.target {
        case .session(let id):
            mutate { $0.removeSession(id: id) }
            try? keychain.deletePassword(account: KeychainStore.sessionAccount(id))
        case .folder(let id):
            mutate { $0.removeFolder(id: id) }
        }
        sidebarSelection = nil
    }

    /// Handles a sidebar drag payload ("session:<uuid>" / "folder:<uuid>").
    @discardableResult
    public func handleDrop(_ payloads: [String], into folderID: UUID?) -> Bool {
        var handled = false
        for payload in payloads {
            guard let item = SidebarItem(dragPayload: payload) else { continue }
            switch item {
            case .session(let id), .favorite(let id):
                move(sessionID: id, to: folderID)
                handled = true
            case .folder(let id):
                guard id != folderID else { continue }
                move(folderID: id, to: folderID)
                handled = true
            }
        }
        return handled
    }

    // MARK: Connecting & tabs

    public func connect(sessionID: UUID) {
        guard let session = library.session(id: sessionID) else { return }
        if session.x11Forwarding && !x11.isAvailable {
            x11MissingRequest = session
            return
        }
        openTab(.ssh(session, isSaved: true))
    }

    /// Connects once with X11 turned off (the saved session is unchanged).
    public func connectWithoutX11(_ session: Session) {
        var copy = session
        copy.x11Forwarding = false
        openTab(.ssh(copy, isSaved: true))
    }

    public func connectSelection() {
        if let id = sidebarSelection?.sessionID { connect(sessionID: id) }
    }

    /// Opens a tab with the user's login shell on this Mac.
    public func openLocalTerminal() {
        openTab(.local)
    }

    func openTab(_ target: TerminalTab.Target) {
        let tab = TerminalTab(target: target, launcher: launcher)
        tab.terminalView.setFontSize(fontSize)
        tab.terminalView.highlighter.isEnabled = highlightOutput
        tab.terminalView.pasteSettings = pasteSettings
        tab.terminalView.pasteReviewHandler = { [weak self, weak tab] review, done in
            guard let window = tab?.terminalView.window else {
                done(nil)
                return
            }
            PasteReviewController.present(review, on: window) { outcome in
                if outcome.stopAsking { self?.confirmMultilinePaste = false }
                done(outcome.text)
                if let terminal = tab?.terminalView { window.makeFirstResponder(terminal) }
            }
        }
        if case .local = target { tab.localBanner = localBannerOptions }
        if case .ssh(let session, _) = target {
            usedSocketPrefixes.insert(SSHCommandBuilder.controlSocketName(for: session))
        }
        if case .ssh(_, isSaved: true) = target {
            tab.onLaunched = { [weak self] session in
                self?.mutate { lib in
                    guard var s = lib.session(id: session.id) else { return }
                    s.lastConnectedAt = Date()
                    lib.upsert(s)
                }
            }
        }
        if case .ssh = target {
            fileBrowsers[tab.id] = FileBrowserModel(tab: tab, builder: launcher.builder)
            monitors[tab.id] = ServerMonitor(tab: tab)
        }
        tabs.append(tab)
        selectedTabID = tab.id
        tab.connect()
    }

    private var pasteSettings: PasteSettings {
        PasteSettings(confirmMultiline: confirmMultilinePaste, typography: pasteTypography)
    }

    private func applyPasteSettings() {
        for tab in tabs { tab.terminalView.pasteSettings = pasteSettings }
    }

    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        fileBrowsers.removeValue(forKey: id)?.disconnect()
        monitors[id] = nil
        tabs[index].close()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    public func closeOtherTabs(_ id: UUID) {
        for tab in tabs where tab.id != id { closeTab(tab.id) }
    }

    public func closeSelectedTabOrWindow() {
        // ⌘W in an editor window closes that window, not a terminal tab.
        if let key = NSApp.keyWindow, key.windowController is RemoteEditorWindowController {
            key.performClose(nil)
        } else if let id = selectedTabID {
            closeTab(id)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    public func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        openTab(tab.target)
    }

    /// Gives keyboard focus to the selected terminal (or to nothing), so the
    /// sidebar selection turns gray.
    public func focusTerminal() {
        guard let window = NSApp.keyWindow else { return }
        if let terminal = selectedTab?.terminalView, terminal.window === window {
            window.makeFirstResponder(terminal)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    public func reconnectSelectedTab() {
        selectedTab?.reconnect()
    }

    public func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    public func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        // ⌘9 always selects the last tab, as in Safari.
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    public func moveTab(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    public func isConnected(_ sessionID: UUID) -> Bool {
        tabs.contains { $0.session?.id == sessionID && $0.state == .running }
    }

    // MARK: Appearance

    public func adjustFontSize(by delta: CGFloat) {
        setFontSize(fontSize + delta)
    }

    public func resetFontSize() {
        setFontSize(AXTerminalView.defaultFontSize)
    }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, 8), 36)
        UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeKey)
        for tab in tabs { tab.terminalView.setFontSize(fontSize) }
    }

    public var recentSessions: [Session] {
        library.sessions
            .filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(6)
            .map { $0 }
    }
}
