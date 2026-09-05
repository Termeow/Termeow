import AppKit
import Foundation

public enum KeyMapper {
    public static func data(for event: NSEvent) -> Data? {
        if event.modifierFlags.contains(.command) {
            return nil
        }
        if let special = special(event) {
            return special
        }
        if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first {
            let value = scalar.value
            if value >= 64 && value <= 95 {
                return Data([UInt8(value - 64)])
            }
            if value >= 97 && value <= 122 {
                return Data([UInt8(value - 96)])
            }
        }
        if let chars = event.characters, !chars.isEmpty {
            return Data(chars.utf8)
        }
        return nil
    }

    private static func special(_ event: NSEvent) -> Data? {
        switch event.keyCode {
        case 36: return Data([0x0d])
        case 48: return Data([0x09])
        case 51: return Data([0x7f])
        case 53: return Data([0x1b])
        case 123: return Data("\u{1b}[D".utf8)
        case 124: return Data("\u{1b}[C".utf8)
        case 125: return Data("\u{1b}[B".utf8)
        case 126: return Data("\u{1b}[A".utf8)
        case 115: return Data("\u{1b}[H".utf8)
        case 119: return Data("\u{1b}[F".utf8)
        case 116: return Data("\u{1b}[5~".utf8)
        case 121: return Data("\u{1b}[6~".utf8)
        case 117: return Data("\u{1b}[3~".utf8)
        case 122: return Data("\u{1b}OP".utf8)
        case 120: return Data("\u{1b}OQ".utf8)
        case 99: return Data("\u{1b}OR".utf8)
        case 118: return Data("\u{1b}OS".utf8)
        default: return nil
        }
    }
}
