import Foundation
import Testing
@testable import TermeowKit

@Test func terminalScrollbackClampsLineCount() {
    #expect(TerminalScrollback(lines: 10).clamped().lines == TerminalScrollback.minLines)
    #expect(TerminalScrollback(lines: 1_000_000).clamped().lines == TerminalScrollback.maxLines)
}

@Test func terminalScrollbackPersistsAndReloads() {
    let suiteName = "cn.termeow.Termeow.scrollback-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(TerminalScrollback.load(from: defaults) == .default)

    let saved = TerminalScrollback(lines: 25_000)
    saved.save(to: defaults)
    #expect(TerminalScrollback.load(from: defaults) == saved)
}

@Test @MainActor func terminalViewAppliesScrollbackLimit() {
    let view = SSHTerminalView(scrollback: TerminalScrollback(lines: 2_000))
    #expect(view.terminal.options.scrollback == 2_000)

    view.applyScrollback(TerminalScrollback(lines: 4_000))
    #expect(view.terminal.options.scrollback == 4_000)
}
