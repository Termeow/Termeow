import Foundation

public enum SFTPItemKind: Equatable, Sendable {
    case file
    case directory
    case symbolicLink
}

public struct SFTPItem: Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: SFTPItemKind
    public let size: UInt64?
    public let permissions: UInt32?
    public let modificationDate: Date?

    public var isDirectory: Bool { kind == .directory }

    public init(
        name: String,
        path: String,
        kind: SFTPItemKind,
        size: UInt64? = nil,
        permissions: UInt32? = nil,
        modificationDate: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
    }
}

public struct SFTPDirectory: Sendable {
    public let path: String
    public let items: [SFTPItem]

    public init(path: String, items: [SFTPItem]) {
        self.path = path
        self.items = items
    }
}

public enum SFTPPath {
    public static func joining(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/\(name)" }
        var base = directory
        while base.count > 1 && base.hasSuffix("/") {
            base.removeLast()
        }
        return "\(base)/\(name)"
    }

    public static func parent(of path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return "/" }
        return "/" + components.dropLast().joined(separator: "/")
    }

    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            return false
        }
        return trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
