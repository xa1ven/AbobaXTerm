import AppKit

/// Plain-text code editor: a TextKit 1 `NSTextView` in a scroll view with a
/// line-number gutter and background syntax highlighting.
@MainActor
public final class CodeEditor: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    public let scrollView: NSScrollView
    public let textView: CodeTextView
    private let ruler: LineNumberRuler

    /// Called after the user changes the text.
    public var onTextChange: (() -> Void)?
    /// Called when the caret moves: (line, column), both 1-based.
    public var onCaretChange: ((Int, Int) -> Void)?

    public var language: SyntaxLanguage {
        didSet {
            guard language != oldValue else { return }
            highlighter = SyntaxHighlighter(language: language)
            highlightNow()
        }
    }

    public var font: NSFont {
        didSet { applyFont() }
    }

    public var wrapsLines = false {
        didSet { applyWrapping() }
    }

    /// Files above this size are shown without highlighting.
    public var highlightLimit = 3_000_000

    private var highlighter: SyntaxHighlighter
    private var highlightTask: Task<Void, Never>?
    private var textVersion = 0
    private var isLoading = false

    public init(language: SyntaxLanguage = .plain, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
        self.language = language
        self.font = font
        self.highlighter = SyntaxHighlighter(language: language)

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CodeTheme.background
        scrollView.documentView = textView

        ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        super.init()
        configureTextView()
        storage.delegate = self
        textView.delegate = self
        applyFont()
        applyWrapping()
    }

    private func configureTextView() {
        let tv = textView
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.backgroundColor = CodeTheme.background
        tv.drawsBackground = true
        tv.textColor = CodeTheme.text
        tv.insertionPointColor = .controlAccentColor
    }

    // MARK: Content

    public var string: String {
        get { textView.string }
        set {
            isLoading = true
            textView.string = newValue
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            applyFont()
            textDidChangeInternally()
            isLoading = false
        }
    }

    public func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Appearance

    private func applyFont() {
        let style = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        style.defaultTabInterval = space * 4
        style.tabStops = []
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CodeTheme.text, .paragraphStyle: style]
        textView.typingAttributes = attrs
        textView.defaultParagraphStyle = style
        if let storage = textView.textStorage, storage.length > 0 {
            let wasLoading = isLoading
            isLoading = true
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            isLoading = wasLoading
        }
        ruler.font = .monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
        ruler.invalidate()
    }

    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        if wrapsLines {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        ruler.invalidate()
    }

    // MARK: Delegates

    public nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                        range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard !isLoading else { return }
            textDidChangeInternally()
            onTextChange?()
        }
    }

    public nonisolated func textViewDidChangeSelection(_ notification: Notification) {
        MainActor.assumeIsolated { reportCaret() }
    }

    private func reportCaret() {
        guard let onCaretChange else { return }
        let ns = textView.string as NSString
        let location = min(textView.selectedRange().location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        let line = ruler.lineNumber(at: location)
        onCaretChange(line, location - lineRange.location + 1)
    }

    private func textDidChangeInternally() {
        textVersion += 1
        ruler.textDidChange()
        scheduleHighlight(delay: .milliseconds(isLoading ? 0 : 120))
    }

    // MARK: Highlighting

    private func highlightNow() {
        scheduleHighlight(delay: .zero)
    }

    private func scheduleHighlight(delay: Duration) {
        highlightTask?.cancel()
        let version = textVersion
        let text = textView.string
        let highlighter = highlighter
        let limit = highlightLimit
        highlightTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let tokens: [SyntaxToken] = (text.utf16.count > limit) ? [] : await Task.detached(priority: .userInitiated) {
                highlighter.tokens(in: text)
            }.value
            guard !Task.isCancelled, let self, self.textVersion == version else { return }
            self.apply(tokens)
        }
    }

    private func apply(_ tokens: [SyntaxToken]) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        let full = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for token in tokens where NSMaxRange(token.range) <= length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: CodeTheme.color(for: token.kind), forCharacterRange: token.range)
        }
    }
}

/// Text view with editor conveniences (auto-indent).
public final class CodeTextView: NSTextView {
    public override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }
}
