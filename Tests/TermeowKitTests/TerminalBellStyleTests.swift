import Foundation
import Testing
@testable import TermeowKit

@Test func terminalBellStylePersistsAndRejectsUnknownValues() {
    let suiteName = "cn.termeow.Termeow.bell-style-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(TerminalBellStyle.load(from: defaults) == .default)

    TerminalBellStyle.soundAndVisual.save(to: defaults)
    #expect(TerminalBellStyle.load(from: defaults) == .soundAndVisual)

    defaults.set("unknown", forKey: "terminalBellStyle")
    #expect(TerminalBellStyle.load(from: defaults) == .default)
}

@Test @MainActor func terminalViewAppliesEveryBellStyle() {
    let view = SSHTerminalView(bellStyle: .none)

    for style in TerminalBellStyle.allCases {
        view.applyBellStyle(style)
        #expect(view.bellStyle.tagName == style.rawValue)
    }
}
