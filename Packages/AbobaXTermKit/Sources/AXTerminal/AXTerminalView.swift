import AXL10n
import AppKit
import Synchronization
import SwiftTerm

/// Events from a terminal's child process, delivered on the main actor.
@MainActor
public protocol AXTerminalViewDelegate: AnyObject {
    func terminalTitleChanged(_ title: String)
    func terminalDirectoryChanged(_ directory: String?)
    func terminalProcessTerminated(exitCode: Int32?)
    func terminalProcessFailedToStart(_ message: String)
}

/// SwiftTerm view running a child process in a PTY.
///
/// Unlike SwiftTerm's `LocalProcessTerminalView`, output is routed through
/// `OutputHighlighter` on the main thread before it reaches the emulator,
/// and the view follows the system light/dark appearance.
public final class AXTerminalView: TerminalView {
    public static let defaultFontSize: CGFloat = 13

    public weak var processDelegate: AXTerminalViewDelegate?
    public let highlighter = OutputHighlighter()
    public var pasteSettings = PasteSettings()
    /// Shows a paste to the user before it is sent. The completion gets the
    /// (possibly edited) text to send, or nil when the user cancelled.
    /// Without a handler every paste goes straight to the terminal.
    public var pasteReviewHandler: ((PasteReview, @escaping @MainActor (String?) -> Void) -> Void)?

    /// Gets a link the user ⌘-clicked, already checked by SwiftTerm.
    /// Without a handler the system opens it.
    public var linkOpenHandler: ((URL) -> Void)?

    private var process: LocalProcess!
    private var bridge: ProcessBridge!
    private var flushWork: DispatchWorkItem?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        terminalDelegate = self
        bridge = ProcessBridge(view: self)
        process = LocalProcess(delegate: bridge, dispatchQueue: .main)
        font = NSFont.monospacedSystemFont(ofSize: Self.defaultFontSize, weight: .regular)
        applyTheme()
    }

    // MARK: Process

    public var isProcessRunning: Bool { process.running }

    public func startProcess(executable: String, args: [String], environment: [String],
                             execName: String, currentDirectory: String? = nil) {
        bridge.windowSize.withLock { $0 = currentWindowSize() }
        process.startProcess(executable: executable, args: args, environment: environment,
                             execName: execName, currentDirectory: currentDirectory)
    }

    public func terminate() {
        process.terminate()
    }

    fileprivate func receive(_ slice: ArraySlice<UInt8>) {
        let bytes = highlighter.process(slice)
        if !bytes.isEmpty { feed(byteArray: bytes[...]) }

        flushWork?.cancel()
        flushWork = nil
        if highlighter.hasPendingOutput {
            // Held-back tail of bulk output: show it if nothing else arrives soon.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let rest = self.highlighter.flush()
                if !rest.isEmpty { self.feed(byteArray: rest[...]) }
            }
            flushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15), execute: work)
        }
    }

    fileprivate func processEnded(exitCode: Int32?) {
        flushWork?.cancel()
        let rest = highlighter.flush()
        if !rest.isEmpty { feed(byteArray: rest[...]) }
        processDelegate?.terminalProcessTerminated(exitCode: exitCode)
    }

    fileprivate func processFailed(_ error: LocalProcessError) {
        feed(text: "\r\n" + L("Process launch failed: %@", "\(error)") + "\r\n")
        processDelegate?.terminalProcessFailedToStart("\(error)")
    }

    private func currentWindowSize() -> winsize {
        let dims = terminalDimensions
        return winsize(ws_row: UInt16(max(dims.rows, 1)), ws_col: UInt16(max(dims.cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
    }

    private func syncWindowSize() {
        var size = currentWindowSize()
        let previous = bridge.windowSize.withLock { old -> winsize in
            let prev = old
            old = size
            return prev
        }
        guard size.ws_row != previous.ws_row || size.ws_col != previous.ws_col else { return }
        if process.running { _ = process.updateWindowSize(&size) }
    }

    // MARK: Paste

    public override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string), offerPaste(text) else {
            super.paste(sender)
            return
        }
    }

    /// Applies the paste settings to `text`: sends a corrected copy or asks
    /// the user first. Returns false when the text needs neither, so the
    /// caller pastes it the usual way.
    @discardableResult
    public func offerPaste(_ text: String) -> Bool {
        guard pasteReviewHandler != nil, process.running else { return false }
        let alternate = terminalInputStateSnapshot()?.isAlternateBuffer ?? false
        switch PastePolicy.decide(text: text, settings: pasteSettings, isAlternateScreen: alternate) {
        case .passThrough:
            return false
        case .send(let fixed):
            pasteText(fixed)
        case .review(let review):
            pasteReviewHandler?(review) { [weak self] edited in
                guard let self, let edited, !edited.isEmpty else { return }
                self.pasteText(edited)
            }
        }
        return true
    }

    #if DEBUG
    /// Center of the cell `offset` characters into the first `text` on the
    /// screen, in view coordinates (debug snapshots click there).
    public func pointOnScreen(of text: String, offset: Int) -> NSPoint? {
        // Rows of the buffer; the same as rows of the screen until it scrolls.
        let dims = terminalDimensions
        let lines = String(decoding: getBufferAsData(), as: UTF8.self).components(separatedBy: "\n")
        for (row, line) in lines.enumerated() where row < dims.rows {
            guard let range = line.range(of: text) else { continue }
            let column = line.distance(from: line.startIndex, to: range.lowerBound) + offset
            return NSPoint(x: (CGFloat(column) + 0.5) * bounds.width / CGFloat(dims.cols),
                           y: bounds.height - (CGFloat(row) + 0.5) * bounds.height / CGFloat(dims.rows))
        }
        return nil
    }
    #endif

    // MARK: Appearance

    public func setFontSize(_ size: CGFloat) {
        font = NSFont.monospacedSystemFont(ofSize: min(max(size, 8), 36), weight: .regular)
    }

    public var fontSize: CGFloat { font.pointSize }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { syncWindowSize() }
    }

    private func applyTheme() {
        let theme = TerminalTheme.current(for: effectiveAppearance)
        installColors(theme.ansi)
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        caretColor = theme.cursor
        needsDisplay = true
    }
}

extension AXTerminalView: TerminalViewDelegate {
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        syncWindowSize()
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.terminalTitleChanged(title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.terminalDirectoryChanged(directory)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    public func scrolled(source: TerminalView, position: Double) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        if let linkOpenHandler { linkOpenHandler(url) } else { NSWorkspace.shared.open(url) }
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }
}

/// LocalProcess delegate; callbacks arrive on the main queue.
private final class ProcessBridge: LocalProcessDelegate, @unchecked Sendable {
    weak var view: AXTerminalView?
    /// Read by LocalProcess when it starts the child (possibly off the main actor).
    let windowSize = Mutex(winsize(ws_row: 25, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0))

    init(view: AXTerminalView) {
        self.view = view
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { view?.receive(slice) }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated { view?.processEnded(exitCode: exitCode) }
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        MainActor.assumeIsolated { view?.processFailed(error) }
    }

    func getWindowSize() -> winsize {
        windowSize.withLock { $0 }
    }
}
