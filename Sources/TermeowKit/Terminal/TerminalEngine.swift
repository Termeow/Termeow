import Foundation
import SwiftTerm

public final class TerminalEngine: @unchecked Sendable {
    public var onSend: (@Sendable (Data) -> Void)?
    public var onDirty: (@Sendable (_ startRow: Int, _ endRow: Int) -> Void)?

    private let queue = DispatchQueue(label: "cn.termeow.Termeow.terminal")
    private let box = DelegateBox()
    private let terminal: Terminal

    public init(cols: Int = 80, rows: Int = 24) {
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        terminal = Terminal(delegate: box, options: options)
        box.owner = self
    }

    public func feed(_ data: Data) {
        queue.sync {
            terminal.feed(byteArray: [UInt8](data))
            notifyDirty()
        }
    }

    public func resize(cols: Int, rows: Int) {
        queue.sync {
            terminal.resize(cols: cols, rows: rows)
            notifyDirty()
        }
    }

    public var cols: Int { queue.sync { terminal.cols } }
    public var rows: Int { queue.sync { terminal.rows } }

    public func snapshot() -> TerminalSnapshot {
        queue.sync {
            let dims = terminal.getDims()
            var lines: [[TerminalCell]] = []
            lines.reserveCapacity(dims.rows)
            for row in 0..<dims.rows {
                var cells: [TerminalCell] = []
                cells.reserveCapacity(dims.cols)
                for col in 0..<dims.cols {
                    let data = terminal.getCharData(col: col, row: row)
                    let ch = data.map { terminal.getCharacter(for: $0) } ?? " "
                    let attr = data?.attribute ?? .empty
                    cells.append(TerminalCell(character: ch, style: TerminalCellStyle(attr), columns: Int(data?.width ?? 1)))
                }
                lines.append(cells)
            }
            let cursor = terminal.getCursorLocation()
            return TerminalSnapshot(
                cols: dims.cols,
                rows: dims.rows,
                lines: lines,
                cursorCol: cursor.x,
                cursorRow: cursor.y
            )
        }
    }

    public func text(from start: (col: Int, row: Int), to end: (col: Int, row: Int)) -> String {
        queue.sync {
            terminal.getText(
                start: Position(col: start.col, row: start.row),
                end: Position(col: end.col, row: end.row)
            )
        }
    }

    public func allText() -> String {
        let dims = queue.sync { terminal.getDims() }
        return text(from: (0, 0), to: (max(dims.cols - 1, 0), max(dims.rows - 1, 0)))
    }

    public func search(query: String, caseSensitive: Bool) -> [TerminalSearchHit] {
        guard !query.isEmpty else { return [] }
        let snap = snapshot()
        var hits: [TerminalSearchHit] = []
        let needle = caseSensitive ? query : query.lowercased()
        for row in 0..<snap.rows {
            let line = snap.lines[row].filter { $0.columns != 0 }.map { String($0.character) }.joined()
            let haystack = caseSensitive ? line : line.lowercased()
            var start = haystack.startIndex
            while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
                let col = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                let endCol = col + query.count - 1
                hits.append(TerminalSearchHit(startCol: col, startRow: row, endCol: endCol, endRow: row))
                start = range.upperBound
            }
        }
        return hits
    }

    fileprivate func handleSend(_ data: ArraySlice<UInt8>) {
        onSend?(Data(data))
    }

    private func notifyDirty() {
        let range = terminal.getUpdateRange() ?? (startY: 0, endY: max(terminal.rows - 1, 0))
        terminal.clearUpdateRange()
        onDirty?(range.startY, range.endY)
    }

    private final class DelegateBox: TerminalDelegate {
        weak var owner: TerminalEngine?

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            owner?.handleSend(data)
        }
    }
}

public struct TerminalCellStyle: Sendable, Equatable {
    public var fg: TerminalColorSpec
    public var bg: TerminalColorSpec
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var inverse: Bool
    public var dim: Bool

    public init(_ attribute: Attribute) {
        fg = TerminalColorSpec(attribute.fg)
        bg = TerminalColorSpec(attribute.bg)
        bold = attribute.style.contains(.bold)
        italic = attribute.style.contains(.italic)
        underline = attribute.style.contains(.underline)
        inverse = attribute.style.contains(.inverse)
        dim = attribute.style.contains(.dim)
    }
}

public enum TerminalColorSpec: Sendable, Equatable {
    case `default`
    case defaultInverted
    case ansi256(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    public init(_ color: Attribute.Color) {
        switch color {
        case .defaultColor: self = .default
        case .defaultInvertedColor: self = .defaultInverted
        case .ansi256(let code): self = .ansi256(code)
        case .trueColor(let r, let g, let b): self = .rgb(r, g, b)
        }
    }
}

public struct TerminalCell: Sendable, Equatable {
    public var character: Character
    public var style: TerminalCellStyle
    public var columns: Int
}

public struct TerminalSnapshot: Sendable {
    public var cols: Int
    public var rows: Int
    public var lines: [[TerminalCell]]
    public var cursorCol: Int
    public var cursorRow: Int
}

public struct TerminalSearchHit: Sendable, Equatable {
    public var startCol: Int
    public var startRow: Int
    public var endCol: Int
    public var endRow: Int
}
