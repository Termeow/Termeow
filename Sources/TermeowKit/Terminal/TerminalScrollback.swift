import Foundation

public struct TerminalScrollback: Equatable, Sendable {
    public var lines: Int

    public static let minLines = 500
    public static let maxLines = 100_000
    public static let `default` = TerminalScrollback(lines: 10_000)

    public init(lines: Int) {
        self.lines = lines
    }

    public func clamped() -> TerminalScrollback {
        TerminalScrollback(lines: min(Self.maxLines, max(Self.minLines, lines)))
    }

    public static func load(from defaults: UserDefaults = .standard) -> TerminalScrollback {
        TerminalScrollback(
            lines: defaults.object(forKey: Keys.lines) as? Int ?? Self.default.lines
        ).clamped()
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(clamped().lines, forKey: Keys.lines)
    }

    private enum Keys {
        static let lines = "terminalScrollbackLines"
    }
}
