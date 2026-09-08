import Foundation

public enum TerminalBellStyle: String, CaseIterable, Identifiable, Sendable {
    case none
    case sound
    case visual
    case soundAndVisual

    public static let `default`: TerminalBellStyle = .sound

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "None"
        case .sound: "Sound"
        case .visual: "Visual"
        case .soundAndVisual: "Sound and Visual"
        }
    }

    public static func load(from defaults: UserDefaults = .standard) -> TerminalBellStyle {
        defaults.string(forKey: Keys.style).flatMap(TerminalBellStyle.init(rawValue:)) ?? .default
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Keys.style)
    }

    private enum Keys {
        static let style = "terminalBellStyle"
    }
}
