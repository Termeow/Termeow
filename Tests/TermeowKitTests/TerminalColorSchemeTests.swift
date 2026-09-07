import AppKit
import Foundation
import Testing
@testable import TermeowKit

@Test func terminalColorSchemeIDsHaveSixteenANSIColors() {
    for id in TerminalColorSchemeID.allCases {
        #expect(id.scheme.ansi.count == 16)
        #expect(id.scheme.background != id.scheme.foreground)
    }
}

@Test func terminalColorSchemeLightAndDarkUseDifferentBackgrounds() {
    #expect(TerminalColorScheme.dark.background != TerminalColorScheme.light.background)
    #expect(TerminalColorScheme.solarizedDark.background != TerminalColorScheme.solarizedLight.background)
    #expect(TerminalColorSchemeID.dark.isDark)
    #expect(!TerminalColorSchemeID.light.isDark)
}

@Test func terminalColorSchemeIDFallsBackToDark() {
    #expect(TerminalColorSchemeID.resolved(nil) == .dark)
    #expect(TerminalColorSchemeID.resolved("not-a-scheme") == .dark)
    #expect(TerminalColorSchemeID.resolved("solarizedLight") == .solarizedLight)
}

@Test func terminalColorSchemeIDPersistsAndReloads() {
    let suiteName = "cn.termeow.Termeow.color-scheme-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(TerminalColorSchemeID.load(from: defaults) == .dark)
    TerminalColorSchemeID.light.save(to: defaults)
    #expect(TerminalColorSchemeID.load(from: defaults) == .light)
}

@Test @MainActor func terminalViewAppliesColorScheme() {
    let view = SSHTerminalView()
    #expect(view.nativeBackgroundColor == TerminalColorScheme.dark.background)

    view.applyColorScheme(.light)
    #expect(view.nativeBackgroundColor == TerminalColorScheme.light.background)
    #expect(view.nativeForegroundColor == TerminalColorScheme.light.foreground)
}
