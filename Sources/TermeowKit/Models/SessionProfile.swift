import Foundation

public enum AuthMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case password
    case privateKey

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .password: NSLocalizedString("Password", bundle: .module, comment: "SSH authentication method")
        case .privateKey: NSLocalizedString("Private Key", bundle: .module, comment: "SSH authentication method")
        }
    }
}

public struct SessionProfile: Codable, Equatable, Identifiable, Sendable {
    public static let validPortRange = 1 ... 65_535

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    public var privateKeyBookmark: Data?
    public var startupCommand: String
    public var groupName: String
    public var isFavorite: Bool
    public var credentialID: UUID
    public var keepAliveSeconds: Int
    public var timeoutSeconds: Int
    public var term: String

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        privateKeyBookmark: Data? = nil,
        startupCommand: String = "",
        groupName: String = "",
        isFavorite: Bool = false,
        credentialID: UUID = UUID(),
        keepAliveSeconds: Int = 60,
        timeoutSeconds: Int = 30,
        term: String = "xterm-256color"
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyBookmark = privateKeyBookmark
        self.startupCommand = startupCommand
        self.groupName = groupName
        self.isFavorite = isFavorite
        self.credentialID = credentialID
        self.keepAliveSeconds = keepAliveSeconds
        self.timeoutSeconds = timeoutSeconds
        self.term = term
    }

    public var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    public var isValidForSaving: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.validPortRange.contains(port)
            && timeoutSeconds > 0
            && keepAliveSeconds >= 0
    }
}
