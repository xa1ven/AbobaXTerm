import AXL10n
import AppKit
import AXModels
import AXStorage
import AXSSH
import SwiftUI

/// Collapsible parts of the session editor.
public enum EditorSection: String, CaseIterable, Identifiable, Sendable {
    case authentication = "Authentication"
    case advanced = "Advanced"
    case organization = "Organization"

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .authentication: L("Authentication")
        case .advanced: L("Advanced")
        case .organization: L("Organization")
        }
    }
}

struct SessionEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let request: EditorRequest

    @State private var session: Session
    @State private var portText: String
    @State private var userText: String
    @State private var jumpText: String
    @State private var authKind: AuthMethod.Kind
    @State private var keyPath: String
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var keys: [SSHKeyInfo] = []
    @State private var expanded: EditorSection?

    init(request: EditorRequest) {
        self.request = request
        let s = request.session
        _session = State(initialValue: s)
        _portText = State(initialValue: s.port.map(String.init) ?? "")
        _userText = State(initialValue: s.user ?? "")
        _jumpText = State(initialValue: s.jumpHost ?? "")
        _authKind = State(initialValue: s.auth.kind)
        _expanded = State(initialValue: request.initialSection)
        if case .publicKey(let path) = s.auth {
            _keyPath = State(initialValue: path)
        } else {
            _keyPath = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(request.isNew ? L("New Session") : L("Edit Session"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 2)
            Form {
                Section {
                    TextField(L("Host"), text: $session.host, prompt: Text(""))
                    TextField(L("Name"), text: $session.name, prompt: Text(""))
                    TextField(L("User"), text: $userText, prompt: Text(""))
                    TextField(L("Port"), text: $portText, prompt: Text("22"))
                }

                Section {
                    // Nothing is selected at first: the short form is enough
                    // for most sessions. A segment opens its rows.
                    Picker(L("Section"), selection: $expanded) {
                        ForEach(EditorSection.allCases) { section in
                            Text(section.title).tag(EditorSection?.some(section))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    switch expanded {
                    case .authentication: authenticationRows
                    case .advanced: advancedRows
                    case .organization: organizationRows
                    case nil: EmptyView()
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            footer
        }
        .frame(width: 520)
        .animation(Motion.standard, value: expanded)
        // A click on the window behind closes the sheet only while nothing
        // has been typed; otherwise the edits would be lost without a word.
        .background(OutsideClickMonitor { if !hasChanges { dismiss() } })
        .onAppear {
            keys = SSHKeyScanner.scan()
            if !request.isNew { hasSavedPassword = model.hasSavedPassword(for: session.id) }
            if authKind == .publicKey, keyPath.isEmpty { keyPath = keys.first?.path ?? "" }
        }
        .onChange(of: authKind) { _, kind in
            if kind == .publicKey, keyPath.isEmpty { keyPath = keys.first?.path ?? "" }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var authenticationRows: some View {
        Group {
            Picker(L("Method"), selection: $authKind) {
                Text(L("SSH config / agent")).tag(AuthMethod.Kind.system)
                Text(L("Key file")).tag(AuthMethod.Kind.publicKey)
                Text(L("Password")).tag(AuthMethod.Kind.password)
            }
            switch authKind {
            case .system:
                EmptyView()
            case .publicKey:
                HStack {
                    Picker(L("Key"), selection: $keyPath) {
                        if keyPath.isEmpty {
                            Text(L("None")).tag("")
                        }
                        ForEach(keys) { key in
                            Text(key.type.map { "\(key.fileName)  (\($0))" } ?? key.fileName).tag(key.path)
                        }
                        if !keyPath.isEmpty, !keys.contains(where: { $0.path == keyPath }) {
                            Text(keyPath).tag(keyPath)
                        }
                    }
                    Button(L("Choose…"), action: chooseKeyFile)
                }
            case .password:
                SecureField(L("Password"), text: $password, prompt: Text(""))
                if hasSavedPassword {
                    LabeledContent(L("Saved in Keychain")) {
                        Button(L("Remove"), role: .destructive) {
                            model.removeSavedPassword(for: session.id)
                            hasSavedPassword = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var advancedRows: some View {
        Group {
            TextField(L("Jump host"), text: $jumpText, prompt: Text(""))
            TextField(L("Extra options"), text: $session.extraOptions, prompt: Text(""))
                .font(.system(.body, design: .monospaced))
            Toggle(isOn: $session.x11Forwarding) {
                Text(L("X11 forwarding"))
                Text(L("Programs started on the server open as windows on this Mac."))
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L("Command")) {
                Text(validationError == nil ? model.commandLinePreview(for: composed) : "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private var organizationRows: some View {
        Group {
            Picker(L("Folder"), selection: $session.folderID) {
                Text(L("Top Level")).tag(UUID?.none)
                ForEach(sortedFolders) { folder in
                    Text(model.library.path(of: folder.id)).tag(UUID?.some(folder.id))
                }
            }
            LabeledContent(L("Color")) {
                HStack(spacing: 6) {
                    colorSwatch(nil)
                    ForEach(SessionColor.allCases, id: \.self) { colorSwatch($0) }
                }
            }
            Picker(L("Icon"), selection: Binding(
                get: { session.icon ?? SessionIcon.default },
                set: { session.icon = $0 == SessionIcon.default ? nil : $0 }
            )) {
                ForEach(SessionIcon.all, id: \.self) { name in
                    Label(SessionIcon.title(of: name), systemImage: name).tag(name)
                }
            }
            Toggle(L("Favorite"), isOn: $session.isFavorite)
            TextField(L("Notes"), text: $session.notes, prompt: Text(""), axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private func colorSwatch(_ color: SessionColor?) -> some View {
        let selected = session.color == color
        return Button {
            session.color = color
        } label: {
            Circle()
                .fill(color?.color ?? Color.secondary.opacity(0.25))
                .frame(width: 16, height: 16)
                .overlay {
                    if selected {
                        Circle().strokeBorder(.primary, lineWidth: 2).frame(width: 20, height: 20)
                    }
                }
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(color.map { L($0.rawValue.capitalized) } ?? L("Default"))
    }

    private var footer: some View {
        HStack {
            if let validationError, !session.host.trimmingCharacters(in: .whitespaces).isEmpty {
                Label {
                    Text(validationError)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.callout)
                .lineLimit(2)
            }
            Spacer()
            Button(L("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Save & Connect")) { save(connect: true) }
                .disabled(validationError != nil)
            Button(request.isNew ? L("Create") : L("Save")) { save(connect: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil)
        }
        .padding(16)
    }

    // MARK: Logic

    private var sortedFolders: [Folder] {
        model.library.folders.sorted {
            model.library.path(of: $0.id).localizedStandardCompare(model.library.path(of: $1.id)) == .orderedAscending
        }
    }

    /// The session as it would be saved right now.
    private var composed: Session {
        var s = session
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        s.port = Int(portText.trimmingCharacters(in: .whitespaces))
        let user = userText.trimmingCharacters(in: .whitespaces)
        s.user = user.isEmpty ? nil : user
        let jump = jumpText.trimmingCharacters(in: .whitespaces)
        s.jumpHost = jump.isEmpty ? nil : jump
        switch authKind {
        case .system: s.auth = .system
        case .password: s.auth = .password
        case .publicKey: s.auth = .publicKey(path: keyPath)
        }
        return s
    }

    /// Whether anything differs from what the sheet opened with.
    private var hasChanges: Bool {
        var original = request.session
        original.host = original.host.trimmingCharacters(in: .whitespaces)
        original.name = original.name.trimmingCharacters(in: .whitespaces)
        return composed != original || !password.isEmpty
    }

    private var validationError: String? {
        let port = portText.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty, Int(port).map({ (1...65535).contains($0) }) != true {
            return L("Port must be a number from 1 to 65535")
        }
        if session.host.trimmingCharacters(in: .whitespaces).isEmpty {
            return L("Host is required")
        }
        do {
            _ = try model.launcher.builder.arguments(for: composed)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func save(connect: Bool) {
        let result = composed
        model.saveSession(result, password: authKind == .password && !password.isEmpty ? password : nil)
        dismiss()
        if connect { model.connect(sessionID: result.id) }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = L("Choose Private Key")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SSHKeyScanner.defaultDirectory
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path
        }
    }
}

extension SessionIcon {
    /// Name shown in the icon menu, instead of the symbol's technical name.
    static func title(of symbol: String) -> String {
        switch symbol {
        case "terminal": L("Terminal")
        case "server.rack": L("Server")
        case "desktopcomputer": L("Desktop Computer")
        case "laptopcomputer": L("Laptop")
        case "cloud": L("Cloud")
        case "cpu": L("Processor")
        case "network": L("Network")
        case "externaldrive": L("Drive")
        case "house": L("Home")
        case "building.2": L("Office")
        case "shield": L("Security")
        case "globe": L("Internet")
        case "flask": L("Lab")
        case "hammer": L("Build")
        case "gamecontroller": L("Games")
        case "display": L("Display")
        default: symbol
        }
    }
}

/// Calls `onOutsideClick` when the user clicks the parent window behind the
/// sheet this view lives in (the click itself is swallowed).
private struct OutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onOutsideClick = onOutsideClick
    }

    final class MonitorView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let clickedWindowNumber = event.windowNumber
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let sheet = self.window, let parent = sheet.sheetParent,
                          parent.windowNumber == clickedWindowNumber else { return false }
                    self.onOutsideClick?()
                    return true
                }
                return handled ? nil : event
            }
        }
    }
}
