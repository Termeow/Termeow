import AppKit
import CoreText

public final class TerminalRendererView: NSView, @preconcurrency NSTextInputClient {
    public var engine: TerminalEngine
    public var scheme: TerminalColorScheme = .default
    public var onInput: ((Data) -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var onPasteConfirm: ((String) -> Void)?
    public var onSelectionChanged: (() -> Void)?

    public var searchHits: [TerminalSearchHit] = [] {
        didSet { needsDisplay = true }
    }
    public var activeHitIndex: Int? {
        didSet { needsDisplay = true }
    }

    private var snapshot = TerminalSnapshot(cols: 80, rows: 24, lines: [], cursorCol: 0, cursorRow: 0)
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var baseline: CGFloat = 12
    private var lastCols = 0
    private var lastRows = 0
    private var marked = ""
    private var selection: Selection?
    private var dragAnchor: (col: Int, row: Int)?
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italicFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldItalicFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private let hitFill = NSColor.systemYellow.withAlphaComponent(0.35)

    public init(engine: TerminalEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = scheme.background.cgColor
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        measureFont()
        engine.onDirty = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.needsDisplay = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let cols = max(Int(bounds.width / max(cellWidth, 1)), 2)
        let rows = max(Int(bounds.height / max(cellHeight, 1)), 1)
        guard cols != lastCols || rows != lastRows else { return }
        lastCols = cols
        lastRows = rows
        engine.resize(cols: cols, rows: rows)
        onResize?(cols, rows)
    }

    public override func draw(_ dirtyRect: NSRect) {
        snapshot = engine.snapshot()
        scheme.background.setFill()
        dirtyRect.fill()

        let startRow = max(Int(dirtyRect.minY / cellHeight), 0)
        let endRow = min(Int(ceil(dirtyRect.maxY / cellHeight)), snapshot.rows)
        guard startRow < endRow else {
            drawCursorAndMarked(in: dirtyRect)
            return
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for row in startRow..<endRow {
            guard row < snapshot.lines.count else { continue }
            let line = snapshot.lines[row]
            var col = 0
            while col < line.count {
                let cell = line[col]
                if cell.columns == 0 {
                    col += 1
                    continue
                }
                var bg = scheme.nsColor(for: cell.style.bg, isBackground: true)
                var fg = scheme.nsColor(for: cell.style.fg, isBackground: false)
                if cell.style.inverse { swap(&bg, &fg) }
                var runEnd = col + 1
                if cell.columns <= 1 {
                    while runEnd < line.count {
                        let next = line[runEnd]
                        if next.columns != 1 || next.style != cell.style { break }
                        runEnd += 1
                    }
                }
                let cols = cell.columns > 1 ? cell.columns : (runEnd - col)
                let rect = CGRect(
                    x: CGFloat(col) * cellWidth,
                    y: CGFloat(row) * cellHeight,
                    width: CGFloat(cols) * cellWidth,
                    height: cellHeight
                )
                if bg != scheme.background {
                    bg.setFill()
                    rect.fill()
                }
                let selected = isSelected(col: col, row: row)
                let hit = isHit(col: col, row: row)
                if selected || hit {
                    (hit ? hitFill : scheme.selection).setFill()
                    rect.fill()
                }
                let origin = CGPoint(x: CGFloat(col) * cellWidth, y: CGFloat(row) * cellHeight)
                if cell.columns > 1 {
                    drawRun(String(cell.character), fg: fg, style: cell.style, origin: origin, in: ctx)
                    col += 1
                } else {
                    var text = ""
                    var visible = cell.style.underline
                    text.reserveCapacity(runEnd - col)
                    for i in col..<runEnd {
                        let ch = line[i].character
                        text.append(ch)
                        if ch != " " { visible = true }
                    }
                    if visible {
                        drawRun(text, fg: fg, style: cell.style, origin: origin, in: ctx)
                    }
                    col = runEnd
                }
            }
        }
        ctx.restoreGState()
        drawCursorAndMarked(in: dirtyRect)
    }

    public override func keyDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        if event.modifierFlags.contains(.command) {
            interpretKeyEvents([event])
            return
        }
        if let data = KeyMapper.data(for: event) {
            clearSelection()
            onInput?(data)
            return
        }
        interpretKeyEvents([event])
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let cell = cellAt(event)
        if event.clickCount == 3 {
            selection = Selection(startCol: 0, startRow: cell.row, endCol: max(snapshot.cols - 1, 0), endRow: cell.row)
        } else if event.clickCount == 2 {
            selection = wordSelection(at: cell)
        } else {
            selection = Selection(startCol: cell.col, startRow: cell.row, endCol: cell.col, endRow: cell.row)
            dragAnchor = cell
        }
        onSelectionChanged?()
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let cell = cellAt(event)
        selection = Selection(startCol: anchor.col, startRow: anchor.row, endCol: cell.col, endRow: cell.row)
        onSelectionChanged?()
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
    }

    @objc public func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { return }
        if PastePolicy.needsConfirmation(text) {
            onPasteConfirm?(text)
        } else {
            onInput?(Data(text.utf8))
        }
    }

    public override func selectAll(_ sender: Any?) {
        selection = Selection(startCol: 0, startRow: 0, endCol: max(snapshot.cols - 1, 0), endRow: max(snapshot.rows - 1, 0))
        onSelectionChanged?()
        needsDisplay = true
    }

    public func pasteConfirmed(_ text: String) {
        onInput?(Data(text.utf8))
    }

    public func selectedText() -> String? {
        guard let selection else { return nil }
        let a = selection.normalized
        return engine.text(from: (a.startCol, a.startRow), to: (a.endCol, a.endRow))
    }

    public var hasSelection: Bool {
        selectedText()?.isEmpty == false
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        marked = ""
        if !text.isEmpty {
            onInput?(Data(text.utf8))
        }
        needsDisplay = true
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        needsDisplay = true
    }

    public func unmarkText() {
        marked = ""
        needsDisplay = true
    }

    public func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    public func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
    }
    public func hasMarkedText() -> Bool { !marked.isEmpty }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = CGRect(
            x: CGFloat(snapshot.cursorCol) * cellWidth,
            y: CGFloat(snapshot.cursorRow) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public override func doCommand(by selector: Selector) {
        if responds(to: selector) {
            perform(selector, with: nil)
        }
    }

    private func measureFont() {
        if let named = NSFont(name: "SF Mono", size: 13) {
            font = named
        }
        boldFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: font.pointSize) ?? font
        italicFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        boldItalicFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits([.bold, .italic]), size: font.pointSize) ?? boldFont
        let ctFont = font as CTFont
        var glyph = CTFontGetGlyphWithName(ctFont, "M" as CFString)
        var advance = CGSize.zero
        if glyph != 0 {
            CTFontGetAdvancesForGlyphs(ctFont, .default, &glyph, &advance, 1)
            cellWidth = max(advance.width, 1)
        } else {
            cellWidth = max(("M" as NSString).size(withAttributes: [.font: font]).width, 1)
        }
        cellHeight = max(font.ascender - font.descender + font.leading, 1)
        baseline = font.ascender
    }

    private func font(for style: TerminalCellStyle) -> NSFont {
        if style.bold && style.italic { return boldItalicFont }
        if style.bold { return boldFont }
        if style.italic { return italicFont }
        return font
    }

    private func drawRun(_ text: String, fg: NSColor, style: TerminalCellStyle, origin: CGPoint, in ctx: CGContext) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(for: style),
            .foregroundColor: style.dim ? fg.withAlphaComponent(0.65) : fg,
        ]
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: origin.x, y: origin.y + baseline)
        CTLineDraw(line, ctx)
    }

    private func drawCursorAndMarked(in dirtyRect: NSRect) {
        let col = snapshot.cursorCol
        let row = snapshot.cursorRow
        let inkHeight = max(ceil(font.ascender - font.descender), 1)
        let cursor = CGRect(
            x: CGFloat(col) * cellWidth,
            y: CGFloat(row) * cellHeight,
            width: 2,
            height: inkHeight
        )
        guard cursor.intersects(dirtyRect) else { return }
        scheme.cursor.setFill()
        cursor.fill()
        if !marked.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: scheme.foreground,
                .backgroundColor: scheme.cursor.withAlphaComponent(0.28),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            (marked as NSString).draw(at: CGPoint(x: cursor.minX, y: cursor.minY), withAttributes: attrs)
        }
    }

    private func cellAt(_ event: NSEvent) -> (col: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let col = min(max(Int(point.x / cellWidth), 0), max(snapshot.cols - 1, 0))
        let row = min(max(Int(point.y / cellHeight), 0), max(snapshot.rows - 1, 0))
        return (col, row)
    }

    private func isSelected(col: Int, row: Int) -> Bool {
        guard let selection else { return false }
        return selection.normalized.contains(col: col, row: row)
    }

    private func isHit(col: Int, row: Int) -> Bool {
        guard let activeHitIndex, searchHits.indices.contains(activeHitIndex) else { return false }
        let hit = searchHits[activeHitIndex]
        return row == hit.startRow && col >= hit.startCol && col <= hit.endCol
    }

    private func wordSelection(at cell: (col: Int, row: Int)) -> Selection {
        guard cell.row < snapshot.lines.count else {
            return Selection(startCol: cell.col, startRow: cell.row, endCol: cell.col, endRow: cell.row)
        }
        let line = snapshot.lines[cell.row]
        var start = cell.col
        var end = cell.col
        func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
        while start > 0, isWord(line[start - 1].character) { start -= 1 }
        while end + 1 < line.count, isWord(line[end + 1].character) { end += 1 }
        return Selection(startCol: start, startRow: cell.row, endCol: end, endRow: cell.row)
    }

    private func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        onSelectionChanged?()
        needsDisplay = true
    }

    private struct Selection {
        var startCol: Int
        var startRow: Int
        var endCol: Int
        var endRow: Int

        var normalized: Selection {
            if (startRow, startCol) <= (endRow, endCol) { return self }
            return Selection(startCol: endCol, startRow: endRow, endCol: startCol, endRow: startRow)
        }

        func contains(col: Int, row: Int) -> Bool {
            let n = normalized
            if row < n.startRow || row > n.endRow { return false }
            if n.startRow == n.endRow { return col >= n.startCol && col <= n.endCol }
            if row == n.startRow { return col >= n.startCol }
            if row == n.endRow { return col <= n.endCol }
            return true
        }
    }
}
