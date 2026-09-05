import Foundation

public struct HostKeyStore: Sendable {
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
        return root.appendingPathComponent("host-keys.json")
    }

    public func load() throws -> [HostKeyRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([HostKeyRecord].self, from: data)
    }

    public func save(_ records: [HostKeyRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func record(host: String, port: Int) throws -> HostKeyRecord? {
        try load().first { $0.host == host && $0.port == port }
    }

    public func upsert(_ record: HostKeyRecord) throws {
        var records = try load()
        records.removeAll { $0.host == record.host && $0.port == record.port }
        records.append(record)
        try save(records)
    }

    public func check(presented: HostKeyRecord) throws -> HostKeyCheck {
        guard let stored = try record(host: presented.host, port: presented.port) else {
            return .unknown(presented)
        }
        if stored.publicKeyBase64 == presented.publicKeyBase64 {
            return .match
        }
        return .mismatch(stored: stored, presented: presented)
    }
}
