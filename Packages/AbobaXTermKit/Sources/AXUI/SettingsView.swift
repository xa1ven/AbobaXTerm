import AXL10n
import AppKit
import AXSSH
import AXTerminal
import SwiftUI

/// Settings window (⌘,).
public struct SettingsView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    /// The pane shown last time; the settings window reopens on it.
    @AppStorage("settingsPane") private var pane = SettingsPane.general

    public var body: some View {
        TabView(selection: $pane) {
            Tab(L("General"), systemImage: "gearshape", value: SettingsPane.general) {
                SettingsPaneForm { generalSections }
            }
            Tab(L("Terminal"), systemImage: "terminal", value: SettingsPane.terminal) {
                SettingsPaneForm { terminalSections }
            }
            Tab("SSH", systemImage: "network", value: SettingsPane.ssh) {
                SettingsPaneForm { sshSections }
            }
            Tab("X11", systemImage: "macwindow.on.rectangle", value: SettingsPane.x11) {
                SettingsPaneForm {
                    Section { X11StatusRow() }
                }
            }
        }
    }

    @ViewBuilder
    private var generalSections: some View {
        @Bindable var model = model

        Section(L("Appearance")) {
            Picker(L("Theme"), selection: $model.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker(selection: Binding(get: { L10n.shared.language }, set: { L10n.shared.language = $0 })) {
                ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
            } label: {
                Text(L("Language"))
                Text(L("The standard menus and file dialogs of macOS switch after AbobaXTerm is restarted."))
            }
        }

        Section(L("Data")) {
            LabeledContent(L("Sessions")) {
                Button(L("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.sessionsFile])
                }
            }
        }
    }

    @ViewBuilder
    private var terminalSections: some View {
        @Bindable var model = model

        Section {
            LabeledContent(L("Font size")) {
                HStack {
                    Text(L("%@ pt", Int(model.fontSize)))
                        .monospacedDigit()
                    Stepper("", onIncrement: { model.adjustFontSize(by: 1) },
                            onDecrement: { model.adjustFontSize(by: -1) })
                        .labelsHidden()
                }
            }
            Toggle(L("Highlight output (IPs, URLs, errors…)"), isOn: $model.highlightOutput)
            LabeledContent(L("Local shell"), value: model.localShellPath)
            Toggle(isOn: $model.showLocalBanner) {
                Text(L("Welcome card in local terminals"))
                Text(L("Shell, ssh and the keyboard shortcuts of AbobaXTerm at the top of every local tab."))
            }
        }

        Section(L("Paste")) {
            Toggle(isOn: $model.confirmMultilinePaste) {
                Text(L("Review several lines before pasting"))
                Text(L("Opens a small editor instead of running every line at once. Not shown in full-screen programs such as vim."))
            }
            Picker(selection: $model.pasteTypography) {
                Text(L("Ask")).tag(TypographyFix.ask)
                Text(L("Fix silently")).tag(TypographyFix.automatic)
                Text(L("Leave as is")).tag(TypographyFix.off)
            } label: {
                Text(L("Typography in pasted commands"))
                Text(L("Chat apps turn \" into « », -- into — and so on, which breaks commands. AbobaXTerm can turn them back."))
            }
        }
    }

    @ViewBuilder
    private var sshSections: some View {
        @Bindable var model = model

        Section {
            Toggle(isOn: $model.showSessionBanner) {
                Text(L("Session summary on connect"))
                Text(L("A short card in the terminal: where the session goes, how it signed in and what is active."))
            }
            Picker(L("Keep connection after last tab closes"), selection: $model.controlPersistMinutes) {
                ForEach(AppModel.controlPersistChoices, id: \.self) { minutes in
                    Text(LN(minutes, "%@ minute", "%@ minutes")).tag(minutes)
                }
            }
        }

        Section(L("Server Monitoring")) {
            Toggle(isOn: $model.monitorEnabled) {
                Text(L("Status bar under SSH terminals"))
                Text(L("CPU, memory, network, uptime and disks of Linux servers, read over the connection that is already open. Nothing is installed on the server."))
            }
            Picker(L("Update every"), selection: $model.monitorInterval) {
                ForEach(AppModel.monitorIntervalChoices, id: \.self) { seconds in
                    Text(LN(seconds, "%@ second", "%@ seconds")).tag(seconds)
                }
            }
            .disabled(!model.monitorEnabled)
        }
    }
}

/// Panes of the settings window, one toolbar button each.
enum SettingsPane: String {
    case general, terminal, ssh, x11
}

/// One pane: a grouped form as tall as its content, so the window fits the pane.
private struct SettingsPaneForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension AppModel {
    var localShellPath: String { TerminalEnvironment.userShell }
}

/// State of the built-in X server.
private struct X11StatusRow: View {
    @Environment(AppModel.self) private var model
    @State private var status = ""
    @State private var isHealthy = true

    var body: some View {
        LabeledContent(L("Built-in X server")) {
            // Color on the symbol only: green or orange text is too faint on a light form.
            Label {
                Text(status)
            } icon: {
                Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isHealthy ? .green : .orange)
            }
        }
        .onAppear(perform: refresh)
        Toggle(isOn: Binding(get: { model.x11HiDPI }, set: { model.x11HiDPI = $0 })) {
            Text(L("Sharp rendering on Retina displays"))
            Text(L("Programs draw at double resolution. Turn off if an old program that cannot scale looks too small. Applies once all X11 windows are closed."))
        }
        Toggle(isOn: Binding(get: { model.x11CommandShortcuts }, set: { model.x11CommandShortcuts = $0 })) {
            Text(L("⌘C, ⌘V, ⌘X, ⌘A and ⌘Z in X11 windows"))
            Text(L("Copy, paste, cut, select all and undo, sent the way each program expects. Turn off to pass Command through as the Super (Windows) key, for example to a virtual machine’s console."))
        }
        Text(L("Sessions with “X11 forwarding” show programs from the server as windows on this Mac. Nothing else needs to be installed."))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func refresh() {
        let x11 = model.x11
        isHealthy = x11.isAvailable
        switch x11.state {
        case _ where !x11.isAvailable:
            status = L("Missing from the app")
        case .running(let display):
            let count = x11.windowCount
            status = L("Running on %@", display) + (count > 0 ? ", " + LN(count, "%@ window", "%@ windows") : "")
        case .starting:
            status = L("Starting…")
        case .failed(let reason):
            status = reason
            isHealthy = false
        case .stopped:
            status = L("Starts with the first X11 session")
        }
    }
}
