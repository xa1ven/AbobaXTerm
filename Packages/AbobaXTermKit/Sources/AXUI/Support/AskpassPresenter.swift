import AXL10n
import AppKit
import AXSSH

/// Shows askpass questions as native alert sheets, one at a time.
@MainActor
final class AskpassPresenter {
    private var tail: Task<Void, Never>?

    nonisolated init() {}

    func present(_ question: AskpassQuestion) async -> AskpassAnswer? {
        let previous = tail
        let task = Task { @MainActor () -> AskpassAnswer? in
            await previous?.value
            return await self.show(question)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func show(_ question: AskpassQuestion) async -> AskpassAnswer? {
        NSApp.activate()
        let alert = NSAlert()
        let prompt = question.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var field: NSTextField?
        var saveBox: NSButton?

        switch question.kind {
        case .password, .passphrase:
            let isPassphrase = if case .passphrase = question.kind { true } else { false }
            alert.messageText = question.isRetry
                ? L("Authentication failed — try again")
                : (isPassphrase ? L("Key passphrase for “%@”", question.sessionName) : L("Password for “%@”", question.sessionName))
            alert.informativeText = prompt
            alert.icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
            let secure = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field = secure
            if question.offerSave {
                let box = NSButton(checkboxWithTitle: L("Save in Keychain"), target: nil, action: nil)
                box.state = .on
                saveBox = box
            }
            alert.accessoryView = stack([secure, saveBox].compactMap { $0 })
            alert.addButton(withTitle: L("Connect"))
            alert.addButton(withTitle: L("Cancel"))

        case .hostKeyConfirmation:
            alert.alertStyle = .warning
            alert.messageText = L("Unknown host key for “%@”", question.sessionName)
            alert.informativeText = prompt
                .replacingOccurrences(of: "Are you sure you want to continue connecting (yes/no/[fingerprint])?", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n" + L("Trust this host and remember its key in ~/.ssh/known_hosts?")
            alert.addButton(withTitle: L("Trust and Connect"))
            alert.addButton(withTitle: L("Cancel"))

        case .confirm:
            alert.messageText = question.sessionName
            alert.informativeText = prompt
            alert.addButton(withTitle: L("Allow"))
            alert.addButton(withTitle: L("Deny"))

        case .notice:
            alert.messageText = question.sessionName
            alert.informativeText = prompt
            alert.addButton(withTitle: L("OK"))

        case .other:
            alert.messageText = L("“%@” asks:", question.sessionName)
            alert.informativeText = prompt
            let plain = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field = plain
            alert.accessoryView = stack([plain])
            alert.addButton(withTitle: L("Send"))
            alert.addButton(withTitle: L("Cancel"))
        }

        if let field { alert.window.initialFirstResponder = field }
        let response = await run(alert)
        guard response == .alertFirstButtonReturn else { return nil }
        return AskpassAnswer(value: field?.stringValue ?? "", save: saveBox?.state == .on)
    }

    private func stack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(views.count) * 30)
        for view in views where view is NSTextField {
            view.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        return stack
    }

    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        guard let window, window.attachedSheet == nil else {
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
