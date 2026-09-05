import Foundation

public struct SessionStore: Sendable {
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
        return root.appendingPathComponent("sessions.json")
    }

    public func load() throws -> [SessionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let list = try JSONDecoder().decode([SessionProfile].self, from: data)
        assertNoSecrets(in: data)
        return list
    }

    public func save(_ profiles: [SessionProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        assertNoSecrets(in: data)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func assertNoSecrets(in data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        // AuthMethod.password encodes as the word "password"; only block key material.
        precondition(!text.contains("BEGIN OPENSSH PRIVATE KEY"), "Session JSON must not store private keys")
        precondition(!text.contains("BEGIN RSA PRIVATE KEY"), "Session JSON must not store private keys")
        precondition(!text.contains("BEGIN PRIVATE KEY"), "Session JSON must not store private keys")
    }
}
