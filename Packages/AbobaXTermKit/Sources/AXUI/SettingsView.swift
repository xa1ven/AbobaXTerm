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
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Terminal") {
                LabeledContent("Font size") {
                    HStack {
                        Text("\(Int(model.fontSize)) pt")
                            .monospacedDigit()
                        Stepper("", onIncrement: { model.adjustFontSize(by: 1) },
                                onDecrement: { model.adjustFontSize(by: -1) })
                            .labelsHidden()
                    }
                }
                Toggle("Highlight output (IPs, URLs, errors…)", isOn: $model.highlightOutput)
                LabeledContent("Local shell", value: model.localShellPath)
            }

            Section("SSH") {
                Picker("Keep connection after last tab closes", selection: $model.controlPersistMinutes) {
                    ForEach(AppModel.controlPersistChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
            }

            Section("X11") {
                X11StatusRow()
            }

            Section("Data") {
                LabeledContent("Sessions") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.paths.sessionsFile])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension AppModel {
    var localShellPath: String { TerminalEnvironment.userShell }
}

/// Whether XQuartz is installed, with the install command if not.
private struct X11StatusRow: View {
    @State private var installed = X11Support.isInstalled

    var body: some View {
        LabeledContent("XQuartz") {
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Text(X11Support.installCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(X11Support.installCommand, forType: .string)
                    }
                }
            }
        }
        .onAppear { installed = X11Support.isInstalled }
        if !installed {
            Text("Needed for X11 forwarding. After installing, log out and back in once.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
