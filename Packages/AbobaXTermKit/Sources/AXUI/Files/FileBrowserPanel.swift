import AXSFTP
import AXTerminal
import SwiftUI

/// Remote files of an SSH tab, shown left of the terminal.
struct FileBrowserPanel: View {
    @Bindable var browser: FileBrowserModel
    let tab: TerminalTab

    var body: some View {
        VStack(spacing: 0) {
            FilePathBar(browser: browser)
            if browser.isSearchVisible && browser.status == .ready {
                FileSearchBar(browser: browser)
            }
            Divider()
            content
                .frame(maxHeight: .infinity)
            if !browser.transfers.items.isEmpty {
                Divider()
                TransferListView(queue: browser.transfers)
            }
        }
        .alert(browser.nameRequest?.title ?? "", isPresented: isPresented(\.nameRequest), presenting: browser.nameRequest) { request in
            FileNameField(browser: browser, request: request)
        }
        .alert(deleteTitle, isPresented: isPresented(\.deleteRequest), presenting: browser.deleteRequest) { request in
            Button("Delete", role: .destructive) { browser.performDelete(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.items.contains(where: \.isDirectory)
                 ? "Folders are deleted with everything inside. This can’t be undone."
                 : "This can’t be undone.")
        }
        .alert(overwriteTitle, isPresented: isPresented(\.overwriteRequest), presenting: browser.overwriteRequest) { request in
            Button("Replace", role: .destructive) { request.perform() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Files with the same name on the server will be overwritten.")
        }
        .alert("File Operation Failed", isPresented: isPresented(\.errorText), presenting: browser.errorText) { _ in
            Button("OK") {}
        } message: { text in
            Text(text)
        }
    }

    @ViewBuilder private var content: some View {
        switch browser.status {
        case .ready:
            FileOutlineView(model: browser, generation: browser.generation)
                .overlay(alignment: .topTrailing) {
                    if browser.isLoading {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
        case .waiting:
            placeholder(icon: nil, text: tab.state.isActive ? "Waiting for the SSH connection…" : "Not connected")
        case .connecting:
            placeholder(icon: nil, text: "Opening SFTP…")
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if tab.state.isActive {
                    Button("Retry") { browser.connect() }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(icon: String?, text: String) -> some View {
        VStack(spacing: 10) {
            if tab.state.isActive { ProgressView().controlSize(.small) }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isPresented<T>(_ keyPath: ReferenceWritableKeyPath<FileBrowserModel, T?>) -> Binding<Bool> {
        Binding(get: { browser[keyPath: keyPath] != nil }, set: { if !$0 { browser[keyPath: keyPath] = nil } })
    }

    private var deleteTitle: String {
        guard let items = browser.deleteRequest?.items else { return "" }
        return items.count == 1 ? "Delete “\(items[0].name)”?" : "Delete \(items.count) items?"
    }

    private var overwriteTitle: String {
        guard let names = browser.overwriteRequest?.names else { return "" }
        return names.count == 1 ? "Replace “\(names[0])”?" : "Replace \(names.count) items?"
    }
}

/// Home, editable path, search, refresh and the "⋯" menu.
private struct FilePathBar: View {
    @Bindable var browser: FileBrowserModel
    @State private var text = ""
    private var ready: Bool { browser.status == .ready }

    var body: some View {
        HStack(spacing: 2) {
            barButton("house", help: "Home Folder") { browser.goHome() }
                .disabled(!ready)
            TextField("Path", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .controlSize(.small)
                .onSubmit { browser.open(text) }
                .disabled(!ready)
                .padding(.horizontal, 4)
            barButton("magnifyingglass", help: "Find in This Folder") { browser.toggleSearch() }
                .disabled(!ready)
                .foregroundStyle(browser.isSearchVisible ? Color.accentColor : Color.primary)
            barButton("arrow.clockwise", help: "Refresh") { browser.refresh() }
                .disabled(!ready)
            Menu {
                Toggle("Show Hidden Files", isOn: $browser.showHidden)
                Button("Copy Current Path") { browser.copyCurrentPath() }
                Divider()
                Button("New Folder…") { browser.requestNewFolder(in: nil) }
                Button("New File…") { browser.requestNewFile(in: nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 24)
            .disabled(!ready)
            .help("More")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .onAppear { text = browser.currentPath }
        .onChange(of: browser.currentPath) { _, new in text = new }
    }

    private func barButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Recursive name search below the current folder; Return / arrows step
/// through matches, revealing each one in the tree.
private struct FileSearchBar: View {
    @Bindable var browser: FileBrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                TextField("Find in “\(SFTPClient.name(of: browser.currentPath))” — e.g. nginx or *.log",
                          text: $browser.searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($focused)
                    .onSubmit { browser.submitSearch() }
                    .onExitCommand { browser.closeSearch() }
                    .padding(.leading, 4)
                    .padding(.trailing, 2)
                Group {
                    if browser.isSearching {
                        ProgressView().controlSize(.mini)
                    } else if let index = browser.searchIndex {
                        Text("\(index + 1)/\(browser.searchResults.count)")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                arrow("chevron.up", help: "Previous Match (⇧↩)") { browser.showSearchResult(offset: -1) }
                arrow("chevron.down", help: "Next Match (↩)") { browser.showSearchResult(offset: 1) }
                arrow("xmark", help: "Close Search (Esc)") { browser.closeSearch() }
            }
            if let message = browser.searchMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .onAppear { focused = true }
        .background {
            // ⇧↩ steps backwards.
            Button("") { browser.showSearchResult(offset: -1) }
                .keyboardShortcut(.return, modifiers: .shift)
                .opacity(0)
        }
    }

    private func arrow(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(icon != "xmark" && browser.searchResults.isEmpty)
    }
}

private struct FileNameField: View {
    let browser: FileBrowserModel
    let request: FileNameRequest
    @State private var name: String

    init(browser: FileBrowserModel, request: FileNameRequest) {
        self.browser = browser
        self.request = request
        _name = State(initialValue: request.name)
    }

    var body: some View {
        TextField("Name", text: $name)
        Button("OK") {
            var updated = request
            updated.name = name
            browser.commitName(updated)
        }
        Button("Cancel", role: .cancel) {}
    }
}

/// Background transfers with progress and cancel.
struct TransferListView: View {
    let queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if queue.items.contains(where: { !$0.state.isActive }) {
                    Button("Clear") { queue.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queue.items) { item in
                        TransferRow(item: item, queue: queue)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TransferRow: View {
    let item: TransferItem
    let queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(iconColor)
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if item.state.isActive {
                    Button {
                        item.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel")
                } else {
                    Button {
                        queue.remove(item)
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from List")
                }
            }
            .font(.callout)
            if item.state == .running || item.state == .queued {
                if let fraction = item.fraction {
                    ProgressView(value: fraction).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(2)
        }
    }

    private var isFailed: Bool {
        if case .failed = item.state { true } else { false }
    }

    private var iconColor: Color {
        switch item.state {
        case .finished: .green
        case .failed: .red
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    private var detail: String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(item.doneBytes), countStyle: .file)
        switch item.state {
        case .queued: return "Waiting…"
        case .running:
            guard let total = item.totalBytes else { return "Preparing… \(done)" }
            return "\(done) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
        case .finished: return "Done — \(done)"
        case .cancelled: return "Cancelled"
        case .failed(let message): return message
        }
    }
}
