@preconcurrency import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH

enum SSHAgentAuthentication {
    static func method(username: String, configuration: SSHAgentConfiguration, access: SSHAgentAccess, timeout: TimeInterval) throws -> SSHAuthenticationMethod {
        .custom(AgentAuthenticationDelegate(username: username, key: try key(configuration: configuration, access: access, timeout: timeout)))
    }

    static func key(configuration: SSHAgentConfiguration, access: SSHAgentAccess, timeout: TimeInterval) throws -> NIOSSHPrivateKey {
        guard let identity = configuration.identity else { throw SSHAgentError.missingIdentity }
        guard identity.isSupported else { throw SSHAgentError.unsupportedKey }
        let signer = AgentSigner(identity: identity, path: try configuration.resolvedSocketPath(), access: access, timeout: timeout)
        switch identity.algorithm {
        case "ssh-ed25519": return NIOSSHPrivateKey(custom: AgentPrivateKey<AgentEd25519>(signer: signer))
        case "ecdsa-sha2-nistp256": return NIOSSHPrivateKey(custom: AgentPrivateKey<AgentP256>(signer: signer))
        case "ecdsa-sha2-nistp384": return NIOSSHPrivateKey(custom: AgentPrivateKey<AgentP384>(signer: signer))
        case "ecdsa-sha2-nistp521": return NIOSSHPrivateKey(custom: AgentPrivateKey<AgentP521>(signer: signer))
        case "ssh-rsa":
            if configuration.rsaSHA256 { return NIOSSHPrivateKey(custom: AgentPrivateKey<AgentRSA256>(signer: signer)) }
            return NIOSSHPrivateKey(custom: AgentPrivateKey<AgentRSA512>(signer: signer))
        default: throw SSHAgentError.unsupportedKey
        }
    }
}

private final class AgentAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPrivateKey
    private let lock = NSLock()
    private var offered = false
    init(username: String, key: NIOSSHPrivateKey) { self.username = username; self.key = key }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        lock.lock(); let shouldOffer = !offered; offered = true; lock.unlock()
        guard shouldOffer, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHError.authenticationFailed)
            return
        }
        // One pinned identity, one attempt. Never silently try every key in a personal agent.
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
    }
}

struct AgentSigner {
    let identity: SSHAgentIdentity
    let path: String
    let access: SSHAgentAccess
    let timeout: TimeInterval

    func sign(_ message: Data, algorithm: String) throws -> Data {
        do {
            // A user certificate can occupy 64 KiB before the SSH authentication fields.
            guard message.count <= 131_072 else { throw SSHAgentError.invalidResponse }
            var request = AgentWire(Data([13]))
            request.append(identity.blob); request.append(message)
            request.append(UInt32(algorithm == "rsa-sha2-512" ? 4 : algorithm == "rsa-sha2-256" ? 2 : 0))
            let response = try access.request(path: path, payload: request.data, timeout: timeout)
            var outer = AgentWire(response)
            guard try outer.byte() == 14 else { throw response == Data([5]) ? SSHAgentError.refused : .invalidResponse }
            var signature = AgentWire(try outer.bytes(limit: 16_384))
            guard outer.isEmpty, try signature.string() == algorithm else { throw SSHAgentError.invalidSignature }
            let raw = try signature.bytes(limit: 8192)
            guard signature.isEmpty, try SSHAgentKeyMaterial(identity: identity).verify(raw, algorithm: algorithm, message: message) else {
                throw SSHAgentError.invalidSignature
            }
            return raw
        } catch {
            let failure = (error as? SSHAgentError) ?? .invalidSignature
            access.record(failure)
            throw failure
        }
    }
}

private protocol AgentAlgorithm { static var name: String { get } }
private enum AgentEd25519: AgentAlgorithm { static let name = "ssh-ed25519" }
private enum AgentP256: AgentAlgorithm { static let name = "ecdsa-sha2-nistp256" }
private enum AgentP384: AgentAlgorithm { static let name = "ecdsa-sha2-nistp384" }
private enum AgentP521: AgentAlgorithm { static let name = "ecdsa-sha2-nistp521" }
private enum AgentRSA512: AgentAlgorithm { static let name = "rsa-sha2-512" }
private enum AgentRSA256: AgentAlgorithm { static let name = "rsa-sha2-256" }

private struct AgentPrivateKey<Algorithm: AgentAlgorithm>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Algorithm.name }
    let signer: AgentSigner
    var publicKey: NIOSSHPublicKeyProtocol { AgentPublicKey<Algorithm>(identity: signer.identity) }

    // The pinned NIOSSH API signs synchronously. Agent routes use a dedicated event loop,
    // with a separate cancellation handle and a bounded socket deadline (never the UI loop).
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        AgentSignature<Algorithm>(rawRepresentation: try signer.sign(Data(data), algorithm: Algorithm.name))
    }
}

private struct AgentPublicKey<Algorithm: AgentAlgorithm>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Algorithm.name }
    let identity: SSHAgentIdentity
    var rawRepresentation: Data { Data(identity.blob.dropFirst(4 + identity.algorithm.utf8.count)) }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? AgentSignature<Algorithm>, let key = try? SSHAgentKeyMaterial(identity: identity) else { return false }
        return key.verify(signature.rawRepresentation, algorithm: Algorithm.name, message: Data(data))
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        let start = buffer.writerIndex
        if identity.algorithm == "ssh-rsa" {
            // RFC 8332: the authentication algorithm is rsa-sha2-*, but the key blob is ssh-rsa.
            // NIOSSH's outgoing custom-key hook otherwise uses one prefix for both. Replace
            // only its immediately preceding, exact prefix; leave headerless writes intact.
            var prefix = AgentWire(); prefix.append(Algorithm.name)
            let index = start - prefix.data.count
            if index >= buffer.readerIndex, buffer.getBytes(at: index, length: prefix.data.count) == Array(prefix.data) {
                buffer.moveWriterIndex(to: index)
                buffer.writeBytes(identity.blob)
                return buffer.writerIndex - start
            }
        }
        return buffer.writeBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        // This is an outbound identity adapter, never registered as a host-key parser.
        throw SSHAgentError.unsupportedKey
    }
}

private struct AgentSignature<Algorithm: AgentAlgorithm>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Algorithm.name }
    let rawRepresentation: Data
    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation)
    }
    static func read(from buffer: inout ByteBuffer) throws -> Self { throw SSHAgentError.unsupportedKey }
}
