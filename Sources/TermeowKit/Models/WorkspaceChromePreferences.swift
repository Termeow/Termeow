import Foundation

public struct WorkspaceChromePreferences: Equatable, Sendable {
    public var sidebarVisible: Bool
    public var statusBarVisible: Bool

    public static let `default` = WorkspaceChromePreferences(
        sidebarVisible: true,
        statusBarVisible: true
    )

    public init(sidebarVisible: Bool, statusBarVisible: Bool) {
        self.sidebarVisible = sidebarVisible
        self.statusBarVisible = statusBarVisible
    }

    public static func load(from defaults: UserDefaults = .standard) -> WorkspaceChromePreferences {
        WorkspaceChromePreferences(
            sidebarVisible: defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? Self.default.sidebarVisible,
            statusBarVisible: defaults.object(forKey: Keys.statusBarVisible) as? Bool ?? Self.default.statusBarVisible
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(sidebarVisible, forKey: Keys.sidebarVisible)
        defaults.set(statusBarVisible, forKey: Keys.statusBarVisible)
    }

    private enum Keys {
        static let sidebarVisible = "workspaceSidebarVisible"
        static let statusBarVisible = "workspaceStatusBarVisible"
    }
}
