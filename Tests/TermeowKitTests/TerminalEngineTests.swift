import Foundation
import Testing
@testable import TermeowKit

@Test func terminalEngineFeedsTextAndSGR() {
    let engine = TerminalEngine(cols: 40, rows: 8)
    engine.feed(Data("hello".utf8))
    #expect(engine.allText().contains("hello"))

    engine.feed(Data("\u{1b}[2J\u{1b}[H".utf8))
    engine.feed(Data("\u{1b}[31mred\u{1b}[0m".utf8))
    let snap = engine.snapshot()
    #expect(String(snap.lines[0][0].character) == "r")
    #expect(snap.lines[0][0].style.fg == .ansi256(1))
}

@Test func terminalEngineMovesCursorAndClears() {
    let engine = TerminalEngine(cols: 20, rows: 6)
    engine.feed(Data("abc".utf8))
    engine.feed(Data("\u{1b}[1;1H".utf8))
    engine.feed(Data("X".utf8))
    let snap = engine.snapshot()
    #expect(String(snap.lines[0][0].character) == "X")
    #expect(String(snap.lines[0][1].character) == "b")

    engine.feed(Data("\u{1b}[2J\u{1b}[H".utf8))
    let cleared = engine.allText().trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(cleared.isEmpty)
}

@Test func terminalSearchFindsHits() {
    let engine = TerminalEngine(cols: 40, rows: 4)
    engine.feed(Data("Foo bar FOO".utf8))
    #expect(engine.search(query: "foo", caseSensitive: false).count == 2)
    #expect(engine.search(query: "Foo", caseSensitive: true).count == 1)
}

@Test func defaultCellColorsStayReadable() {
    let engine = TerminalEngine(cols: 20, rows: 4)
    engine.feed(Data("hi".utf8))
    let cell = engine.snapshot().lines[0][0]
    #expect(cell.style.fg == .default)
    #expect(cell.style.bg == .default)

    let scheme = TerminalColorScheme.default
    let fg = scheme.nsColor(for: cell.style.fg, isBackground: false)
    let bg = scheme.nsColor(for: cell.style.bg, isBackground: true)
    #expect(fg != bg)
    #expect(fg == scheme.foreground)
    #expect(bg == scheme.background)
    #expect(scheme.nsColor(for: .defaultInverted, isBackground: false) == scheme.background)
    #expect(scheme.nsColor(for: .defaultInverted, isBackground: true) == scheme.foreground)
}

@Test func snapshotFillsEveryVisibleCell() {
    let engine = TerminalEngine(cols: 12, rows: 5)
    engine.feed(Data("ab".utf8))
    let snap = engine.snapshot()
    #expect(snap.cols == 12)
    #expect(snap.rows == 5)
    #expect(snap.lines.count == 5)
    #expect(snap.lines.allSatisfy { $0.count == 12 })
}

@Test func wideCharactersOccupyTwoColumns() {
    let engine = TerminalEngine(cols: 20, rows: 3)
    engine.feed(Data("验收.txt".utf8))
    let line = engine.snapshot().lines[0]
    #expect(String(line[0].character) == "验")
    #expect(line[0].columns == 2)
    #expect(line[1].columns == 0)
    #expect(engine.search(query: "验收", caseSensitive: true).count == 1)
}

@Test func pastePolicyThresholds() {
    #expect(PastePolicy.needsConfirmation("short") == false)
    #expect(PastePolicy.needsConfirmation(String(repeating: "a", count: 3000)))
    #expect(PastePolicy.needsConfirmation("1\n2\n3\n4\n5\n6\n7\n8\n9"))
}
