import Foundation

public enum PastePolicy {
    public static let byteLimit = 2048
    public static let newlineLimit = 8

    public static func needsConfirmation(_ text: String) -> Bool {
        text.utf8.count > byteLimit || text.filter { $0.isNewline }.count >= newlineLimit
    }
}
