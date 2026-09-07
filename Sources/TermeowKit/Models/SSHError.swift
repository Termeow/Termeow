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
            NSLocalizedString("Could not connect to the server.", bundle: .module, comment: "SSH error")
        case .timeout:
            NSLocalizedString("The connection timed out.", bundle: .module, comment: "SSH error")
        case .authenticationFailed:
            NSLocalizedString("Authentication failed.", bundle: .module, comment: "SSH error")
        case .hostKeyChanged:
            NSLocalizedString("The host key has changed. The connection was blocked.", bundle: .module, comment: "SSH error")
        case .unknownHostKey:
            NSLocalizedString("The host key is not trusted.", bundle: .module, comment: "SSH error")
        case .hostKeyRejected:
            NSLocalizedString("The host key was rejected.", bundle: .module, comment: "SSH error")
        case .unsupportedAlgorithm:
            NSLocalizedString("This server or key uses an unsupported algorithm.", bundle: .module, comment: "SSH error")
        case .connectionClosed:
            NSLocalizedString("The connection was closed.", bundle: .module, comment: "SSH error")
        case .invalidPrivateKey:
            NSLocalizedString("The private key could not be read.", bundle: .module, comment: "SSH error")
        case .missingCredential:
            NSLocalizedString("A password or key is required.", bundle: .module, comment: "SSH error")
        }
    }
}

public enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(SSHError)

    public var requiresCloseConfirmation: Bool {
        switch self {
        case .connecting, .connected:
            true
        case .disconnected, .failed:
            false
        }
    }
}
