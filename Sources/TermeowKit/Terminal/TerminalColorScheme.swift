import AppKit
import Foundation

public enum TerminalColorSchemeID: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case solarizedDark
    case solarizedLight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .solarizedDark: "Solarized Dark"
        case .solarizedLight: "Solarized Light"
        }
    }

    public var isDark: Bool {
        switch self {
        case .dark, .solarizedDark: true
        case .light, .solarizedLight: false
        }
    }

    public var scheme: TerminalColorScheme {
        switch self {
        case .dark: .dark
        case .light: .light
        case .solarizedDark: .solarizedDark
        case .solarizedLight: .solarizedLight
        }
    }

    public static func resolved(_ raw: String?) -> TerminalColorSchemeID {
        raw.flatMap(TerminalColorSchemeID.init(rawValue:)) ?? .dark
    }

    public static func load(from defaults: UserDefaults = .standard) -> TerminalColorSchemeID {
        resolved(defaults.string(forKey: Keys.id))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Keys.id)
    }

    private enum Keys {
        static let id = "terminalColorScheme"
    }
}

public struct TerminalColorScheme: @unchecked Sendable {
    public var background: NSColor
    public var foreground: NSColor
    public var cursor: NSColor
    public var selection: NSColor
    public var ansi: [NSColor]
    private let xtermCache = XtermCache()

    public static let `default` = dark

    public static let dark = TerminalColorScheme(
        background: srgb(0.10, 0.10, 0.12),
        foreground: srgb(0.86, 0.87, 0.88),
        cursor: srgb(0.86, 0.87, 0.88),
        selection: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45),
        ansi: [
            srgb(0.07, 0.07, 0.07),
            srgb(0.80, 0.20, 0.20),
            srgb(0.30, 0.70, 0.30),
            srgb(0.80, 0.70, 0.20),
            srgb(0.30, 0.50, 0.80),
            srgb(0.70, 0.40, 0.70),
            srgb(0.30, 0.70, 0.70),
            srgb(0.80, 0.80, 0.80),
            srgb(0.35, 0.35, 0.35),
            srgb(1.00, 0.40, 0.40),
            srgb(0.50, 0.90, 0.50),
            srgb(1.00, 0.90, 0.40),
            srgb(0.50, 0.70, 1.00),
            srgb(0.90, 0.60, 0.90),
            srgb(0.50, 0.90, 0.90),
            srgb(1.00, 1.00, 1.00),
        ]
    )

    public static let light = TerminalColorScheme(
        background: srgb(0.96, 0.96, 0.97),
        foreground: srgb(0.11, 0.11, 0.12),
        cursor: srgb(0.11, 0.11, 0.12),
        selection: srgb(0.78, 0.85, 0.95),
        ansi: [
            srgb(0.11, 0.11, 0.12),
            srgb(0.77, 0.12, 0.23),
            srgb(0.14, 0.54, 0.24),
            srgb(0.60, 0.48, 0.04),
            srgb(0.04, 0.39, 0.78),
            srgb(0.54, 0.27, 0.67),
            srgb(0.06, 0.48, 0.51),
            srgb(0.82, 0.82, 0.84),
            srgb(0.39, 0.39, 0.40),
            srgb(0.88, 0.29, 0.35),
            srgb(0.20, 0.78, 0.35),
            srgb(0.90, 0.76, 0.00),
            srgb(0.25, 0.61, 1.00),
            srgb(0.75, 0.35, 0.95),
            srgb(0.39, 0.82, 1.00),
            srgb(1.00, 1.00, 1.00),
        ]
    )

    public static let solarizedDark = TerminalColorScheme(
        background: hex(0x002B36),
        foreground: hex(0x839496),
        cursor: hex(0x93A1A1),
        selection: hex(0x073642),
        ansi: solarizedANSI
    )

    public static let solarizedLight = TerminalColorScheme(
        background: hex(0xFDF6E3),
        foreground: hex(0x657B83),
        cursor: hex(0x586E75),
        selection: hex(0xEEE8D5),
        ansi: solarizedANSI
    )

    public func nsColor(for spec: TerminalColorSpec, isBackground: Bool) -> NSColor {
        switch spec {
        case .default:
            return isBackground ? background : foreground
        case .defaultInverted:
            return isBackground ? foreground : background
        case .ansi256(let code):
            if code < 16, Int(code) < ansi.count { return ansi[Int(code)] }
            let index = Int(code)
            if let cached = xtermCache.colors[index] { return cached }
            let color = xterm256(code)
            xtermCache.colors[index] = color
            return color
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    private func xterm256(_ code: UInt8) -> NSColor {
        if code < 16 { return foreground }
        if code < 232 {
            let idx = Int(code) - 16
            let r = CGFloat(idx / 36) / 5
            let g = CGFloat((idx % 36) / 6) / 5
            let b = CGFloat(idx % 6) / 5
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        let gray = (CGFloat(Int(code) - 232) * 10 + 8) / 255
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    }
}

private let solarizedANSI: [NSColor] = [
    hex(0x073642),
    hex(0xDC322F),
    hex(0x859900),
    hex(0xB58900),
    hex(0x268BD2),
    hex(0xD33682),
    hex(0x2AA198),
    hex(0xEEE8D5),
    hex(0x002B36),
    hex(0xCB4B16),
    hex(0x586E75),
    hex(0x657B83),
    hex(0x839496),
    hex(0x6C71C4),
    hex(0x93A1A1),
    hex(0xFDF6E3),
]

private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

private func hex(_ value: Int) -> NSColor {
    srgb(
        CGFloat((value >> 16) & 0xFF) / 255,
        CGFloat((value >> 8) & 0xFF) / 255,
        CGFloat(value & 0xFF) / 255
    )
}

private final class XtermCache: @unchecked Sendable {
    var colors: [NSColor?] = Array(repeating: nil, count: 256)
}
