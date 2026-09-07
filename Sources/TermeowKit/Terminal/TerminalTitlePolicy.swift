import Foundation

public enum TerminalTitlePolicy {
    public static let maximumLength = 128

    public static func displayTitle(
        from rawValue: String,
        maximumLength: Int = TerminalTitlePolicy.maximumLength
    ) -> String? {
        guard maximumLength > 0 else { return nil }
        let sanitized = rawValue.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let normalized = sanitized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumLength))
    }
}
