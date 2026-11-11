import AppKit

/// Line-number gutter for a TextKit 1 text view.
@MainActor
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offsets where each line starts (always contains 0).
    private var lineStarts: [Int] = [0]
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func boundsChanged() { needsDisplay = true }

    func invalidate() {
        updateThickness()
        needsDisplay = true
    }

    func textDidChange() {
        guard let text = textView?.string else { return }
        var starts = [0]
        var index = 0
        for unit in text.utf16 {
            index += 1
            if unit == 0x0A { starts.append(index) }
        }
        lineStarts = starts
        invalidate()
    }

    /// 1-based line containing the UTF-16 offset.
    func lineNumber(at offset: Int) -> Int {
        lineIndex(at: offset) + 1
    }

    private func lineIndex(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let width = ("8" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits) + 16
        if abs(ruleThickness - width) > 0.5 { ruleThickness = ceil(width) }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        CodeTheme.background.setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }

        let length = (textView.string as NSString).length
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CodeTheme.gutterText]
        let origin = textView.textContainerOrigin

        var line = lineIndex(at: charRange.location)
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(charRange) {
            let start = lineStarts[line]
            let fragment: NSRect
            if start >= length {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty && length > 0 { break }
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            }
            let y = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            let baselineOffset = (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + baselineOffset), withAttributes: attrs)
            line += 1
        }
    }
}
