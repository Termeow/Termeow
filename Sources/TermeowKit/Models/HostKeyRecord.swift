import Foundation

public struct HostKeyRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(host):\(port)" }
    public var host: String
    public var port: Int
    public var algorithm: String
    public var fingerprintSHA256: String
    public var publicKeyBase64: String
    public var trustedAt: Date

    public init(
        host: String,
        port: Int,
        algorithm: String,
        fingerprintSHA256: String,
        publicKeyBase64: String,
        trustedAt: Date = Date()
    ) {
        self.host = host
        self.port = port
        self.algorithm = algorithm
        self.fingerprintSHA256 = fingerprintSHA256
        self.publicKeyBase64 = publicKeyBase64
        self.trustedAt = trustedAt
    }
}

public enum HostKeyDecision: Sendable {
    case cancel
    case connectOnce
    case trustAndSave
}

public enum HostKeyCheck: Equatable, Sendable {
    case unknown(HostKeyRecord)
    case match
    case mismatch(stored: HostKeyRecord, presented: HostKeyRecord)
}
