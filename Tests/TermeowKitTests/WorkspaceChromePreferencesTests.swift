import Foundation
import Testing
@testable import TermeowKit

@Test func workspaceChromePreferencesDefaultToVisible() {
    let suiteName = "WorkspaceChromePreferencesTests.defaults.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(WorkspaceChromePreferences.load(from: defaults) == .default)
}

@Test func workspaceChromePreferencesPersistVisibility() {
    let suiteName = "WorkspaceChromePreferencesTests.persistence.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = WorkspaceChromePreferences(sidebarVisible: false, statusBarVisible: false)
    preferences.save(to: defaults)

    #expect(WorkspaceChromePreferences.load(from: defaults) == preferences)
}
