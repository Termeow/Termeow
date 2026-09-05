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

@Test func pastePolicyThresholds() {
    #expect(PastePolicy.needsConfirmation("short") == false)
    #expect(PastePolicy.needsConfirmation(String(repeating: "a", count: 3000)))
    #expect(PastePolicy.needsConfirmation("1\n2\n3\n4\n5\n6\n7\n8\n9"))
}
