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

/// State of the built-in X server.
private struct X11StatusRow: View {
    @Environment(AppModel.self) private var model
    @State private var status = ""
    @State private var isHealthy = true

    var body: some View {
        LabeledContent("Built-in X server") {
            Label(status, systemImage: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isHealthy ? .green : .orange)
        }
        .onAppear(perform: refresh)
        Text("Sessions with “X11 forwarding” show programs from the server as windows on this Mac. Nothing else needs to be installed.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func refresh() {
        let x11 = model.x11
        isHealthy = x11.isAvailable
        switch x11.state {
        case _ where !x11.isAvailable:
            status = "Missing from the app"
        case .running(let display):
            let count = x11.windowCount
            status = "Running on \(display)" + (count > 0 ? ", \(count) window\(count == 1 ? "" : "s")" : "")
        case .starting:
            status = "Starting…"
        case .failed(let reason):
            status = reason
            isHealthy = false
        case .stopped:
            status = "Starts with the first X11 session"
        }
    }
}
