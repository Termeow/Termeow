@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

enum CitadelConnectionFactory {
    static func connect(
        profile: SessionProfile,
        secret: String,
        hostKeyStore: HostKeyStore,
        prompt: @escaping HostKeyPromptHandler
    ) async throws -> SSHClient {
        do {
            let auth = AuthBox(try authenticationMethod(profile: profile, secret: secret))
            let validator = PromptingHostKeyValidator(
                host: profile.host,
                port: profile.port,
                store: hostKeyStore,
                prompt: prompt
            )
            var settings = SSHClientSettings(
                host: profile.host,
                port: profile.port,
                authenticationMethod: { auth.method },
                hostKeyValidator: .custom(validator)
            )
            settings.connectTimeout = .seconds(Int64(max(profile.timeoutSeconds, 1)))
            return try await SSHClient.connect(to: settings)
        } catch {
            throw mapError(error)
        }
    }

    static func mapError(_ error: Error) -> SSHError {
        if let ssh = error as? SSHError { return ssh }
        if error is InvalidHostKey { return .unknownHostKey }
        let text = String(describing: error).lowercased()
        if text.contains("auth") { return .authenticationFailed }
        if text.contains("timeout") { return .timeout }
        if text.contains("closed") { return .connectionClosed }
        return .connectionFailed
    }

    private static func authenticationMethod(profile: SessionProfile, secret: String) throws -> SSHAuthenticationMethod {
        switch profile.authMethod {
        case .password:
            guard !secret.isEmpty else { throw SSHError.missingCredential }
            return .passwordBased(username: profile.username, password: secret)
        case .privateKey:
            return try privateKeyAuth(profile: profile, secret: secret)
        }
    }

    private static func privateKeyAuth(profile: SessionProfile, secret: String) throws -> SSHAuthenticationMethod {
        guard let bookmark = profile.privateKeyBookmark else { throw SSHError.invalidPrivateKey }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard url.startAccessingSecurityScopedResource() else { throw SSHError.invalidPrivateKey }
        defer { url.stopAccessingSecurityScopedResource() }
        let keyText = try String(contentsOf: url, encoding: .utf8)
        let passphrase = secret.isEmpty ? nil : Data(secret.utf8)
        let type = try SSHKeyDetection.detectPrivateKeyType(from: keyText)
        switch type {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: passphrase)
            return .ed25519(username: profile.username, privateKey: key)
        case .rsa:
            let key = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: passphrase)
            return .rsa(username: profile.username, privateKey: key)
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            throw SSHError.unsupportedAlgorithm
        default:
            throw SSHError.unsupportedAlgorithm
        }
    }
}

private struct AuthBox: @unchecked Sendable {
    let method: SSHAuthenticationMethod

    init(_ method: SSHAuthenticationMethod) {
        self.method = method
    }
}
