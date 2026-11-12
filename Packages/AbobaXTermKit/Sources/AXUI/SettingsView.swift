import AXL10n
import AppKit
import AXSSH
import SwiftUI

/// Settings window (⌘,).
public struct SettingsView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model

        Form {
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

            Section(L("Terminal")) {
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
            }

            Section(L("SSH")) {
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

            Section("X11") {
                X11StatusRow()
            }

            Section {
                LabeledContent(L("Sessions")) {
                    Button(L("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.paths.sessionsFile])
                    }
                }
            } header: {
                Text(L("Data"))
            } footer: {
                VStack(spacing: 2) {
                    Text(L("Version %@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"))
                    Text(verbatim: "Prod by xa1ven | Mike Dubenskov")
                }
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }
        }
        .formStyle(.grouped)
        // Fixed height: the grouped form scrolls inside the window.
        .frame(width: 480, height: 600)
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
            Label(status, systemImage: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isHealthy ? .green : .orange)
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
