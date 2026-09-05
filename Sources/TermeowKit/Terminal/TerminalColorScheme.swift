import AppKit
import Foundation

public struct TerminalColorScheme: @unchecked Sendable {
    public var background: NSColor
    public var foreground: NSColor
    public var cursor: NSColor
    public var selection: NSColor
    public var ansi: [NSColor]

    public static let `default` = TerminalColorScheme(
        background: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1),
        foreground: NSColor(srgbRed: 0.86, green: 0.87, blue: 0.88, alpha: 1),
        cursor: NSColor.systemGreen,
        selection: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45),
        ansi: [
            NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1),
            NSColor(srgbRed: 0.80, green: 0.20, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.70, blue: 0.30, alpha: 1),
            NSColor(srgbRed: 0.80, green: 0.70, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.50, blue: 0.80, alpha: 1),
            NSColor(srgbRed: 0.70, green: 0.40, blue: 0.70, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.70, blue: 0.70, alpha: 1),
            NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1),
            NSColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.40, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 0.50, green: 0.90, blue: 0.50, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.90, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 0.50, green: 0.70, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.90, green: 0.60, blue: 0.90, alpha: 1),
            NSColor(srgbRed: 0.50, green: 0.90, blue: 0.90, alpha: 1),
            NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        ]
    )

    public func nsColor(for spec: TerminalColorSpec, inverted: Bool) -> NSColor {
        switch spec {
        case .default:
            return inverted ? background : foreground
        case .defaultInverted:
            return inverted ? foreground : background
        case .ansi256(let code):
            if code < 16, Int(code) < ansi.count { return ansi[Int(code)] }
            return xterm256(code)
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
