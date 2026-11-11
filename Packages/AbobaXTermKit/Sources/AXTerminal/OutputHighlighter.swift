import Foundation

/// Adds colors to plain terminal output (IP addresses, URLs, status words…).
///
/// Works on the raw byte stream between the PTY and the terminal emulator:
/// - escape sequences pass through untouched;
/// - only text the program left in the default colors is highlighted, so
///   colored output (ls, git, systemctl…) keeps its own colors;
/// - nothing is touched while the alternate screen is active (vim, htop, mc);
/// - inserted SGR sequences are zero-width, so cursor positions don't change.
///
/// Large chunks may end in the middle of a word; that tail is held back until
/// the next chunk or `flush()`, so words split between reads still match.
///
/// The text already printed on the current line is kept as context, so input
/// echoed one character at a time (a command being typed) is highlighted too:
/// typing `docker ps -a` colors `-a` before Enter is pressed.
public final class OutputHighlighter {
    /// Chunks at least this big are treated as bulk output (tail held back).
    static let bulkThreshold = 256
    static let maxHeldBytes = 512
    /// How much of the current line is kept as context (characters).
    static let maxLineContext = 200

    private enum ParseState {
        case ground
        case escape            // after ESC
        case csi               // ESC [ ... final
        case string            // OSC / DCS / APC / PM / SOS body
        case stringEscape      // ESC inside a string (maybe ST)
    }

    private var state = ParseState.ground
    private var csiBytes: [UInt8] = []

    // SGR state of the program's own output.
    private var foregroundIsDefault = true
    private var backgroundIsDefault = true
    private var inverse = false
    private var alternateScreen = false

    /// Pending plain-text bytes (current run of printable text).
    private var run: [UInt8] = []
    /// Text printed on the current line so far (best effort; cleared when the
    /// cursor moves in ways we don't track).
    private var lineContext = ""

    public var isEnabled = true

    public init() {}

    /// Transforms a chunk of process output.
    public func process(_ input: some Collection<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count + 64)

        for byte in input {
            switch state {
            case .ground:
                if byte == 0x1B {
                    emitRun(into: &out, final: true, forceComplete: true)
                    state = .escape
                    out.append(byte)
                } else if byte < 0x20 && byte != 0x09 || byte == 0x7F {
                    emitRun(into: &out, final: true, forceComplete: true)
                    out.append(byte)
                    switch byte {
                    case 0x08: if !lineContext.isEmpty { lineContext.removeLast() } // backspace
                    case 0x0A, 0x0D: lineContext = ""
                    default: break
                    }
                } else {
                    run.append(byte)
                }

            case .escape:
                out.append(byte)
                switch byte {
                case 0x5B: // [
                    csiBytes.removeAll(keepingCapacity: true)
                    state = .csi
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] P X ^ _
                    state = .string
                case 0x63: // ESC c (full reset)
                    resetAttributes()
                    alternateScreen = false
                    lineContext = ""
                    state = .ground
                case 0x20...0x2F:
                    break // intermediate byte, sequence continues
                default:
                    state = .ground
                }

            case .csi:
                out.append(byte)
                if (0x40...0x7E).contains(byte) {
                    handleCSI(params: csiBytes, final: byte)
                    state = .ground
                } else if csiBytes.count < 64 {
                    csiBytes.append(byte)
                }

            case .string:
                out.append(byte)
                if byte == 0x07 {
                    state = .ground
                } else if byte == 0x1B {
                    state = .stringEscape
                }

            case .stringEscape:
                out.append(byte)
                state = byte == 0x5C ? .ground : .string
            }
        }

        if state == .ground && !run.isEmpty {
            let holdTail = input.count >= Self.bulkThreshold && run.count <= Self.maxHeldBytes
            emitRun(into: &out, final: !holdTail)
        }
        return out
    }

    /// Emits any held-back text (call when no more output arrived for a moment).
    public func flush() -> [UInt8] {
        var out: [UInt8] = []
        emitRun(into: &out, final: true, forceComplete: true)
        return out
    }

    public var hasPendingOutput: Bool { !run.isEmpty }

    // MARK: Escape sequences

    private func handleCSI(params: [UInt8], final: UInt8) {
        let isPrivate = params.first == UInt8(ascii: "?")
        let text = String(decoding: isPrivate ? params.dropFirst() : params[...], as: UTF8.self)

        // Anything but colors (m) and erase-to-end-of-line (K) may move the
        // cursor, so the line context is no longer reliable.
        if final != UInt8(ascii: "m") && final != UInt8(ascii: "K") {
            lineContext = ""
        }

        if isPrivate, final == UInt8(ascii: "h") || final == UInt8(ascii: "l") {
            let modes = text.split(separator: ";").compactMap { Int($0) }
            if modes.contains(where: { [47, 1047, 1049].contains($0) }) {
                alternateScreen = final == UInt8(ascii: "h")
            }
            return
        }
        guard final == UInt8(ascii: "m"), !isPrivate else { return }

        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.split(separator: ":").first.flatMap { Int($0) } ?? 0 }
        if parts.isEmpty || text.isEmpty {
            resetAttributes()
            return
        }
        var i = 0
        while i < parts.count {
            let p = parts[i]
            switch p {
            case 0: resetAttributes()
            case 7: inverse = true
            case 27: inverse = false
            case 30...37, 90...97: foregroundIsDefault = false
            case 39: foregroundIsDefault = true
            case 40...47, 100...107: backgroundIsDefault = false
            case 49: backgroundIsDefault = true
            case 38, 48:
                if p == 38 { foregroundIsDefault = false } else { backgroundIsDefault = false }
                // Skip "5;n" or "2;r;g;b" (colon forms were folded into one part above).
                if i + 1 < parts.count, !text.contains(":") {
                    i += parts[i + 1] == 5 ? 2 : (parts[i + 1] == 2 ? 4 : 0)
                }
            default: break
            }
            i += 1
        }
    }

    private func resetAttributes() {
        foregroundIsDefault = true
        backgroundIsDefault = true
        inverse = false
    }

    // MARK: Text runs

    private func emitRun(into out: inout [UInt8], final: Bool, forceComplete: Bool = false) {
        guard !run.isEmpty else { return }

        // Keep an incomplete UTF-8 character for the next chunk.
        var cut = run.count
        if !forceComplete { cut = Self.completeUTF8Prefix(run) }
        if !final {
            // Hold back the trailing partial word of bulk output.
            if let lastSpace = run[..<cut].lastIndex(where: { $0 == 0x20 || $0 == 0x09 }) {
                cut = lastSpace + 1
            } else {
                cut = 0
            }
        }
        guard cut > 0 else { return }

        let chunk = Array(run[..<cut])
        run.removeFirst(cut)

        guard let text = String(validating: chunk, as: UTF8.self) else {
            out.append(contentsOf: chunk)
            lineContext = ""
            return
        }
        defer { appendContext(text) }
        guard isEnabled, !alternateScreen, foregroundIsDefault, backgroundIsDefault, !inverse else {
            out.append(contentsOf: chunk)
            return
        }
        out.append(contentsOf: HighlightRules.apply(to: text, context: lineContext).utf8)
    }

    private func appendContext(_ text: String) {
        lineContext += text
        if lineContext.count > Self.maxLineContext {
            lineContext = String(lineContext.suffix(Self.maxLineContext))
        }
    }

    /// Length of the longest prefix that does not end inside a UTF-8 sequence.
    static func completeUTF8Prefix(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        var i = n - 1
        var continuation = 0
        while i >= 0, i >= n - 4, bytes[i] & 0xC0 == 0x80 {
            continuation += 1
            i -= 1
        }
        guard i >= 0 else { return n }
        let lead = bytes[i]
        let expected: Int
        switch lead {
        case 0xC0...0xDF: expected = 1
        case 0xE0...0xEF: expected = 2
        case 0xF0...0xF7: expected = 3
        default: return n // ASCII or invalid: nothing to wait for
        }
        return continuation < expected ? i : n
    }
}
