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
        try loadLibrary().profiles
    }

    public func loadLibrary() throws -> SessionLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SessionLibrary() }
        let data = try Data(contentsOf: fileURL)
        assertNoSecrets(in: data)
        if let library = try? JSONDecoder().decode(SessionLibrary.self, from: data) {
            return library
        }
        let profiles = try JSONDecoder().decode([SessionProfile].self, from: data)
        return SessionLibrary(profiles: profiles, groups: groupNames(from: profiles))
    }

    public func save(_ profiles: [SessionProfile]) throws {
        try saveLibrary(SessionLibrary(profiles: profiles, groups: groupNames(from: profiles)))
    }

    public func saveLibrary(_ library: SessionLibrary) throws {
        let data = try JSONEncoder().encode(library)
        assertNoSecrets(in: data)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func groupNames(from profiles: [SessionProfile]) -> [String] {
        var result: [String] = []
        for groupName in profiles.lazy.map(\.groupName) where !groupName.isEmpty {
            if !result.contains(where: { $0.localizedCaseInsensitiveCompare(groupName) == .orderedSame }) {
                result.append(groupName)
            }
        }
        return result
    }

    public func assertNoSecrets(in data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        // AuthMethod.password encodes as the word "password"; only block key material.
        precondition(!text.contains("BEGIN OPENSSH PRIVATE KEY"), "Session JSON must not store private keys")
        precondition(!text.contains("BEGIN RSA PRIVATE KEY"), "Session JSON must not store private keys")
        precondition(!text.contains("BEGIN PRIVATE KEY"), "Session JSON must not store private keys")
    }
}
