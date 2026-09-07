import AppKit
import Foundation
import Testing
@testable import TermeowKit

@Test func terminalTypographyClampsSizeAndLineHeight() {
    let clamped = TerminalTypography(fontName: "  Menlo-Regular  ", fontSize: 3, lineHeight: 0.2).clamped()
    #expect(clamped.fontName == "Menlo-Regular")
    #expect(clamped.fontSize == TerminalTypography.minFontSize)
    #expect(clamped.lineHeight == TerminalTypography.minLineHeight)

    let upper = TerminalTypography(fontName: "", fontSize: 80, lineHeight: 4).clamped()
    #expect(upper.fontSize == TerminalTypography.maxFontSize)
    #expect(upper.lineHeight == TerminalTypography.maxLineHeight)
}

@Test func terminalTypographyFallsBackToSystemMonospaced() {
    let missing = TerminalTypography(fontName: "DefinitelyNotAFont-Regular", fontSize: 16, lineHeight: 1)
    let expected = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    #expect(missing.resolvedFont().fontName == expected.fontName)
    #expect(abs(missing.resolvedFont().pointSize - 16) < 0.01)
}

@Test func terminalTypographyPersistsAndReloads() {
    let suiteName = "cn.termeow.Termeow.typography-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(TerminalTypography.load(from: defaults) == .default)

    let saved = TerminalTypography(fontName: "Menlo-Regular", fontSize: 18, lineHeight: 1.25)
    saved.save(to: defaults)
    #expect(TerminalTypography.load(from: defaults) == saved.clamped())
}

@Test @MainActor func terminalViewAppliesTypography() {
    let view = SSHTerminalView()
    #expect(abs(view.font.pointSize - TerminalTypography.default.fontSize) < 0.01)
    #expect(abs(view.lineSpacing - TerminalTypography.default.lineHeight) < 0.01)

    let typography = TerminalTypography(fontName: "", fontSize: 18, lineHeight: 1.2)
    view.applyTypography(typography)
    #expect(abs(view.font.pointSize - 18) < 0.01)
    #expect(abs(view.lineSpacing - 1.2) < 0.01)
}
