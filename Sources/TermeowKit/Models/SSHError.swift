import Foundation

public enum SSHError: Error, Equatable, Sendable {
    case connectionFailed
    case timeout
    case authenticationFailed
    case hostKeyChanged
    case unknownHostKey
    case hostKeyRejected
    case unsupportedAlgorithm
    case connectionClosed
    case invalidPrivateKey
    case missingCredential

    public var userMessage: String {
        switch self {
        case .connectionFailed:
            "Could not connect to the server."
        case .timeout:
            "The connection timed out."
        case .authenticationFailed:
            "Authentication failed."
        case .hostKeyChanged:
            "The host key has changed. The connection was blocked."
        case .unknownHostKey:
            "The host key is not trusted."
        case .hostKeyRejected:
            "The host key was rejected."
        case .unsupportedAlgorithm:
            "This server or key uses an unsupported algorithm."
        case .connectionClosed:
            "The connection was closed."
        case .invalidPrivateKey:
            "The private key could not be read."
        case .missingCredential:
            "A password or key is required."
        }
    }
}

public enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(SSHError)
}
