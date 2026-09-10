import Foundation

public enum AuthMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case password
    case privateKey
    case agent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .password: NSLocalizedString("Password", bundle: .module, comment: "SSH authentication method")
        case .privateKey: NSLocalizedString("Private Key", bundle: .module, comment: "SSH authentication method")
        case .agent: "SSH Agent"
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
    public var lastUsedAt: Date?
    public var credentialID: UUID
    public var keepAliveSeconds: Int
    public var timeoutSeconds: Int
    public var term: String
    public var jumpHostID: UUID?
    public var portForwards: [PortForwardRule]
    public var agent: SSHAgentConfiguration
    public var certificate: SSHCertificateConfiguration

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
        lastUsedAt: Date? = nil,
        credentialID: UUID = UUID(),
        keepAliveSeconds: Int = 60,
        timeoutSeconds: Int = 30,
        term: String = "xterm-256color",
        jumpHostID: UUID? = nil,
        portForwards: [PortForwardRule] = [],
        agent: SSHAgentConfiguration = SSHAgentConfiguration(),
        certificate: SSHCertificateConfiguration = SSHCertificateConfiguration()
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
        self.lastUsedAt = lastUsedAt
        self.credentialID = credentialID
        self.keepAliveSeconds = keepAliveSeconds
        self.timeoutSeconds = timeoutSeconds
        self.term = term
        self.jumpHostID = jumpHostID
        self.portForwards = portForwards
        self.agent = agent
        self.certificate = certificate
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, privateKeyBookmark, startupCommand, groupName
        case isFavorite, lastUsedAt, credentialID, keepAliveSeconds, timeoutSeconds, term, jumpHostID, portForwards
        case agent, certificate
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        authMethod = try values.decode(AuthMethod.self, forKey: .authMethod)
        privateKeyBookmark = try values.decodeIfPresent(Data.self, forKey: .privateKeyBookmark)
        startupCommand = try values.decode(String.self, forKey: .startupCommand)
        groupName = try values.decode(String.self, forKey: .groupName)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        lastUsedAt = try values.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        credentialID = try values.decode(UUID.self, forKey: .credentialID)
        keepAliveSeconds = try values.decode(Int.self, forKey: .keepAliveSeconds)
        timeoutSeconds = try values.decode(Int.self, forKey: .timeoutSeconds)
        term = try values.decode(String.self, forKey: .term)
        jumpHostID = try values.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        portForwards = try values.decodeIfPresent([PortForwardRule].self, forKey: .portForwards) ?? []
        agent = try values.decodeIfPresent(SSHAgentConfiguration.self, forKey: .agent) ?? SSHAgentConfiguration()
        certificate = try values.decodeIfPresent(SSHCertificateConfiguration.self, forKey: .certificate) ?? SSHCertificateConfiguration()
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
            && (authMethod != .agent || agent.validationError == nil)
            && (!certificate.enabled || (authMethod != .password && certificate.bookmark != nil))
    }
}
