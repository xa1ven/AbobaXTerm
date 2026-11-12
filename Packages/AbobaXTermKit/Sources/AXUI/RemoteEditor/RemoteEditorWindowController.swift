import AXL10n
import AppKit
import AXEditor
import AXSFTP

/// A window editing one remote file. ⌘S writes it back over SFTP; before
/// saving (and when the window becomes active) the file's size and mtime on
/// the server are compared with what was loaded.
@MainActor
final class RemoteEditorWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var open: [String: RemoteEditorWindowController] = [:]

    let path: String
    private weak var browser: FileBrowserModel?
    private let key: String
    let editor = CodeEditor()
    private let statusBar = EditorStatusBar()
    private var baseline: SFTPAttributes?
    private var isDirty = false {
        didSet { window?.isDocumentEdited = isDirty }
    }
    private var isSaving = false
    private var isCheckingServer = false
    /// Shown once per external change, until reload or save.
    private var ignoredServerChange: SFTPAttributes?

    static var hasUnsavedChanges: Bool { open.values.contains { $0.isDirty } }

    /// Opens (or focuses) the editor for `path` in the given browser's session.
    static func open(path: String, browser: FileBrowserModel) {
        let key = "\(ObjectIdentifier(browser).hashValue):\(path)"
        if let existing = open[key] {
            existing.showWindow(nil)
            return
        }
        let controller = RemoteEditorWindowController(path: path, browser: browser, key: key)
        open[key] = controller
        controller.showWindow(nil)
        controller.load()
    }

    private init(path: String, browser: FileBrowserModel, key: String) {
        self.path = path
        self.browser = browser
        self.key = key
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = SFTPClient.name(of: path)
        window.subtitle = "\(browser.hostLabel) — \(path)"
        window.representedURL = nil
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RemoteEditor")
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        buildContent()
        if window.frameAutosaveName.isEmpty || window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        guard let window else { return }
        let container = NSView()
        editor.scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.addSubview(editor.scrollView)
        container.addSubview(statusBar)
        NSLayoutConstraint.activate([
            editor.scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            editor.scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        window.contentView = container

        editor.textView.isEditable = false
        editor.onTextChange = { [weak self] in self?.isDirty = true }
        editor.onCaretChange = { [weak self] line, column in self?.statusBar.setCaret(line: line, column: column) }
        statusBar.onLanguageChange = { [weak self] language in self?.editor.language = language }
        statusBar.onWrapChange = { [weak self] wraps in self?.editor.wrapsLines = wraps }
        statusBar.setMessage(L("Loading…"))
    }

    // MARK: Loading

    private func load() {
        guard let client = browser?.client else {
            fail(L("Not connected."))
            return
        }
        Task {
            do {
                let (data, attrs) = try await client.readFile(path)
                guard let text = Self.decode(data) else {
                    fail(L("This looks like a binary file. Download it instead."))
                    return
                }
                baseline = attrs
                ignoredServerChange = nil
                let language = SyntaxLanguage.detect(fileName: SFTPClient.name(of: path), content: String(text.prefix(512)))
                editor.language = language
                editor.string = text
                editor.textView.isEditable = true
                isDirty = false
                statusBar.setLanguage(language)
                statusBar.setMessage(attrs.permissionString)
                editor.focus()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// UTF-8 text; nil for binary data.
    static func decode(_ data: Data) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Legacy single-byte files still open; saving writes UTF-8.
        return String(data: data, encoding: .isoLatin1)
    }

    private func fail(_ message: String) {
        statusBar.setMessage(message)
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Can’t open “%@”", SFTPClient.name(of: path))
        alert.informativeText = message
        alert.beginSheetModal(for: window) { [weak self] _ in
            MainActor.assumeIsolated { if self?.baseline == nil { self?.close() } }
        }
    }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) {
        save(force: false)
    }

    private func save(force: Bool, then: (() -> Void)? = nil) {
        guard !isSaving, baseline != nil, let window else { return }
        guard let client = browser?.client, !client.isClosed else {
            showError(L("Not connected. Reconnect the session and save again."))
            return
        }
        isSaving = true
        statusBar.setMessage(L("Saving…"))
        let text = editor.string
        Task {
            defer { isSaving = false }
            do {
                if !force, let current = try? await client.attributes(path), changed(current) {
                    isSaving = false
                    askOverwrite(window: window, then: then)
                    return
                }
                try await client.writeFile(path, data: Data(text.utf8))
                baseline = try await client.attributes(path)
                ignoredServerChange = nil
                // Only clear the flag if nothing was typed while saving.
                if editor.string == text { isDirty = false }
                statusBar.setMessage(L("Saved %@", Date().formatted(date: .omitted, time: .standard)))
                browser?.refresh()
                then?()
            } catch {
                statusBar.setMessage(L("Save failed"))
                showError(error.localizedDescription)
            }
        }
    }

    private func changed(_ current: SFTPAttributes) -> Bool {
        guard let baseline else { return false }
        return current.modificationTime != baseline.modificationTime || current.size != baseline.size
    }

    private func askOverwrite(window: NSWindow, then: (() -> Void)?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("“%@” was changed on the server", SFTPClient.name(of: path))
        alert.informativeText = L("Someone or something modified the file after you opened it. Overwrite their changes with yours?")
        alert.addButton(withTitle: L("Overwrite"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Discard Mine and Reload"))
        alert.buttons[2].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self?.save(force: true, then: then)
                case .alertThirdButtonReturn: self?.load()
                default: self?.statusBar.setMessage(L("Not saved"))
                }
            }
        }
    }

    private func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Couldn’t save “%@”", SFTPClient.name(of: path))
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: Server change check

    func windowDidBecomeKey(_ notification: Notification) {
        checkServerCopy()
    }

    private func checkServerCopy() {
        guard !isCheckingServer, !isSaving, baseline != nil, let client = browser?.client, let window,
              window.attachedSheet == nil else { return }
        isCheckingServer = true
        Task { [weak self, path] in
            guard let current = try? await client.attributes(path) else {
                self?.isCheckingServer = false
                return
            }
            guard let self else { return }
            self.isCheckingServer = false
            guard self.changed(current), current != self.ignoredServerChange, window.attachedSheet == nil else { return }
            self.ignoredServerChange = current
            let alert = NSAlert()
            alert.messageText = L("“%@” changed on the server", SFTPClient.name(of: path))
            alert.informativeText = self.isDirty
                ? L("You have unsaved changes. Reloading will discard them.")
                : L("Reload to see the current version?")
            alert.addButton(withTitle: L("Reload"))
            alert.addButton(withTitle: L("Keep My Version"))
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    if response == .alertFirstButtonReturn { self?.load() }
                }
            }
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("Save changes to “%@” on the server?", SFTPClient.name(of: path))
        alert.informativeText = L("Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don’t Save"))
        alert.buttons[2].hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    self.save(force: false) { [weak self] in self?.close() }
                case .alertThirdButtonReturn:
                    self.isDirty = false
                    self.close()
                default:
                    break
                }
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[key] = nil
    }
}

/// Bottom bar: message, caret position, wrap toggle, language picker.
final class EditorStatusBar: NSView {
    var onLanguageChange: ((SyntaxLanguage) -> Void)?
    var onWrapChange: ((Bool) -> Void)?
    private let message = NSTextField(labelWithString: "")
    private let caret = NSTextField(labelWithString: L("Ln 1, Col 1"))
    private let wrap = NSButton(checkboxWithTitle: L("Wrap"), target: nil, action: nil)
    private let language = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        super.init(frame: .zero)
        for field in [message, caret] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
        }
        caret.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        wrap.controlSize = .small
        wrap.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        wrap.target = self
        wrap.action = #selector(wrapChanged)
        language.controlSize = .small
        language.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        language.isBordered = false
        for lang in SyntaxLanguage.allCases {
            language.addItem(withTitle: lang.displayName)
            language.lastItem?.representedObject = lang.rawValue
        }
        language.target = self
        language.action = #selector(languageChanged)

        let divider = NSBox()
        divider.boxType = .separator
        let stack = NSStackView(views: [message, NSView(), caret, wrap, language])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [divider, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: divider.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setMessage(_ text: String) { message.stringValue = text }

    func setCaret(line: Int, column: Int) { caret.stringValue = L("Ln %@, Col %@", line, column) }

    func setLanguage(_ lang: SyntaxLanguage) {
        if let index = SyntaxLanguage.allCases.firstIndex(of: lang) { language.selectItem(at: index) }
    }

    @objc private func languageChanged() {
        guard let raw = language.selectedItem?.representedObject as? String, let lang = SyntaxLanguage(rawValue: raw) else { return }
        onLanguageChange?(lang)
    }

    @objc private func wrapChanged() {
        onWrapChange?(wrap.state == .on)
    }
}
