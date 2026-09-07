import AppKit
import Foundation

public struct TerminalTypography: Equatable, Sendable {
    public var fontName: String
    public var fontSize: Double
    public var lineHeight: Double

    public static let `default` = TerminalTypography(fontName: "", fontSize: 13, lineHeight: 1)
    public static let minFontSize = 9.0
    public static let maxFontSize = 28.0
    public static let minLineHeight = 1.0
    public static let maxLineHeight = 1.8

    public init(fontName: String = "", fontSize: Double = 13, lineHeight: Double = 1) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }

    public func clamped() -> TerminalTypography {
        TerminalTypography(
            fontName: fontName.trimmingCharacters(in: .whitespacesAndNewlines),
            fontSize: min(Self.maxFontSize, max(Self.minFontSize, fontSize)),
            lineHeight: min(Self.maxLineHeight, max(Self.minLineHeight, lineHeight))
        )
    }

    public func resolvedFont() -> NSFont {
        let value = clamped()
        let size = CGFloat(value.fontSize)
        if !value.fontName.isEmpty, let font = NSFont(name: value.fontName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public var statusLabel: String {
        let font = resolvedFont()
        let name = font.displayName ?? font.fontName
        let value = clamped()
        return "\(name) \(Int(value.fontSize.rounded())) · \(String(format: "%.2f", value.lineHeight))"
    }

    public static func load(from defaults: UserDefaults = .standard) -> TerminalTypography {
        TerminalTypography(
            fontName: defaults.string(forKey: Keys.fontName) ?? "",
            fontSize: defaults.object(forKey: Keys.fontSize) as? Double ?? Self.default.fontSize,
            lineHeight: defaults.object(forKey: Keys.lineHeight) as? Double ?? Self.default.lineHeight
        ).clamped()
    }

    public func save(to defaults: UserDefaults = .standard) {
        let value = clamped()
        defaults.set(value.fontName, forKey: Keys.fontName)
        defaults.set(value.fontSize, forKey: Keys.fontSize)
        defaults.set(value.lineHeight, forKey: Keys.lineHeight)
    }

    private enum Keys {
        static let fontName = "terminalFontName"
        static let fontSize = "terminalFontSize"
        static let lineHeight = "terminalLineHeight"
    }
}
