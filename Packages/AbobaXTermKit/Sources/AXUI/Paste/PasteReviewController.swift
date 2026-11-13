import AXL10n
import AXTerminal
import AppKit

/// Sheet with a small editor for text about to be pasted into a terminal:
/// several lines, or text whose quotes and dashes a chat app restyled.
@MainActor
final class PasteReviewController: NSObject, NSTextViewDelegate {
    struct Outcome {
        /// Text to send; nil when cancelled.
        var text: String?
        var stopAsking = false
    }

    private let review: PasteReview
    private let completion: (Outcome) -> Void
    private let panel: NSPanel
    private let textView = NSTextView()
    private var versionControl: NSSegmentedControl?
    private var stopAskingBox: NSButton?
    private let countLabel = NSTextField(labelWithString: "")
    private weak var parent: NSWindow?

    /// Keeps controllers alive while their sheets are open.
    private static var active: [PasteReviewController] = []

    static func present(_ review: PasteReview, on window: NSWindow, completion: @escaping (Outcome) -> Void) {
        guard window.attachedSheet == nil else {
            NSSound.beep()
            completion(Outcome())
            return
        }
        let controller = PasteReviewController(review: review, completion: completion)
        active.append(controller)
        controller.parent = window
        window.beginSheet(controller.panel) { _ in
            active.removeAll { $0 === controller }
        }
    }

    private init(review: PasteReview, completion: @escaping (Outcome) -> Void) {
        self.review = review
        self.completion = completion
        panel = PasteReviewPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        (panel as? PasteReviewPanel)?.onAccept = { [weak self] in self?.paste() }
        (panel as? PasteReviewPanel)?.onCancel = { [weak self] in self?.cancel() }
        panel.contentMinSize = NSSize(width: 460, height: 280)
        buildContent()
        show(fixed: review.sanitized != nil)
    }

    // MARK: Layout

    private func buildContent() {
        let title = NSTextField(labelWithString: review.sanitized == nil
            ? L("Paste several lines?")
            : L("Paste with typography fixed?"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let detail = NSTextField(wrappingLabelWithString: review.sanitized == nil
            ? L("Every line runs as soon as it is pasted. Check the text, edit it here if needed.")
            : L("Quotes, dashes or spaces restyled by a chat app were turned back into plain ones (green). An orange dash could not be guessed: check it."))
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor

        let header = NSStackView(views: [title, detail])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        configureTextView()
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancel.identifier = NSUserInterfaceItemIdentifier("paste-cancel")
        // Return adds a line in the editor, so pasting takes ⌘Return (handled by the panel).
        let paste = NSButton(title: L("Paste") + "  ⌘↩", target: self, action: #selector(paste))
        paste.identifier = NSUserInterfaceItemIdentifier("paste-accept")
        paste.bezelColor = .controlAccentColor

        var bottomViews: [NSView] = []
        if review.sanitized != nil {
            let control = NSSegmentedControl(labels: [L("Fixed"), L("Original")], trackingMode: .selectOne,
                                             target: self, action: #selector(versionChanged))
            control.selectedSegment = 0
            control.controlSize = .small
            versionControl = control
            bottomViews.append(control)
        } else {
            let box = NSButton(checkboxWithTitle: L("Do not ask about several lines"), target: nil, action: nil)
            box.controlSize = .small
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            stopAskingBox = box
            bottomViews.append(box)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomViews += [countLabel, spacer, cancel, paste]
        let bottom = NSStackView(views: bottomViews)
        bottom.orientation = .horizontal
        bottom.spacing = 10

        let root = NSStackView(views: [header, scroll, bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        panel.contentView = content
        panel.initialFirstResponder = textView
    }

    private func configureTextView() {
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // The whole point is to send exactly what is shown.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        // Long lines scroll sideways instead of wrapping: a wrapped command reads as two.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    // MARK: Content

    private func show(fixed: Bool) {
        let text = NSMutableAttributedString(
            string: fixed ? (review.sanitized?.text ?? review.original) : review.original,
            attributes: Self.baseAttributes)
        if fixed, let sanitized = review.sanitized {
            for range in sanitized.fixedRanges {
                text.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.3), range: range)
            }
            for range in sanitized.unresolvedRanges {
                text.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.45), range: range)
                // Not by color alone: green and orange look alike to many people.
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
                text.addAttribute(.underlineColor, value: NSColor.systemOrange, range: range)
            }
        }
        textView.textStorage?.setAttributedString(text)
        textView.typingAttributes = Self.baseAttributes
        textView.setSelectedRange(NSRange(location: text.length, length: 0))
        textView.undoManager?.removeAllActions()
        updateCount()
    }

    private func updateCount() {
        countLabel.stringValue = LN(PastePolicy.lineCount(textView.string), "%@ line", "%@ lines")
    }

    func textDidChange(_ notification: Notification) {
        updateCount()
    }

    /// Typed text must not inherit the highlight of a replaced character next to it.
    func textViewDidChangeSelection(_ notification: Notification) {
        textView.typingAttributes = Self.baseAttributes
    }

    // MARK: Actions

    @objc private func versionChanged() {
        show(fixed: versionControl?.selectedSegment == 0)
    }

    @objc private func paste() {
        finish(Outcome(text: textView.string, stopAsking: stopAskingBox?.state == .on))
    }

    @objc private func cancel() {
        finish(Outcome())
    }

    private func finish(_ outcome: Outcome) {
        parent?.endSheet(panel)
        completion(outcome)
    }
}

/// Sheet window that takes ⌘Return as "paste" and Esc as "cancel" itself:
/// a default button would also fire on plain Return, which the editor needs.
private final class PasteReviewPanel: NSPanel {
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            onAccept?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
