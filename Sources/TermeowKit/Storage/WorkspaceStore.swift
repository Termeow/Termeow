import Foundation

public struct WorkspaceStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("cn.termeow.Termeow", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("workspace.json")
    }

    public func load() throws -> WorkspaceSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return WorkspaceSnapshot() }
        return try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
