@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

enum SSHCertificateAuthentication {
    static func method(base: SSHAuthenticationMethod, certificate: SSHUserCertificate, rsaSHA256: Bool = false) throws -> SSHAuthenticationMethod {
        try certificate.validate()
        return .custom(CertificateAuthenticationDelegate(base: base, certificate: certificate, rsaSHA256: rsaSHA256))
    }

    static func offer(_ original: NIOSSHUserAuthenticationOffer, certificate: SSHUserCertificate, rsaSHA256: Bool = false) throws -> NIOSSHUserAuthenticationOffer {
        guard case .privateKey(var key) = original.offer else { throw SSHCertificateError.invalidAuthentication }
        var encoded = ByteBuffer()
        key.privateKey.publicKey.write(to: &encoded)
        var identity = AgentWire(Data(encoded.readableBytesView))
        let keyAlgorithm = try identity.string()
        var canonical = AgentWire()
        if keyAlgorithm == "rsa-sha2-512" || keyAlgorithm == "rsa-sha2-256" {
            canonical.append("ssh-rsa"); canonical.append(try identity.bytes()); canonical.append(try identity.bytes())
            guard identity.isEmpty else { throw SSHCertificateError.keyMismatch }
        } else { canonical = AgentWire(Data(encoded.readableBytesView)) }
        try certificate.validate(matching: canonical.data)
        switch certificate.publicKey.algorithm {
        case "ssh-ed25519": key.publicKey = publicKey(CertEd25519.self, certificate)
        case "ecdsa-sha2-nistp256": key.publicKey = publicKey(CertP256.self, certificate)
        case "ecdsa-sha2-nistp384": key.publicKey = publicKey(CertP384.self, certificate)
        case "ecdsa-sha2-nistp521": key.publicKey = publicKey(CertP521.self, certificate)
        case "ssh-rsa":
            if rsaSHA256 { key.publicKey = publicKey(CertRSA256.self, certificate) }
            else { key.publicKey = publicKey(CertRSA512.self, certificate) }
        default: throw SSHCertificateError.unsupportedKey
        }
        var offer = original; offer.offer = .privateKey(key)
        return offer
    }

    static func rsaMethod(username: String, key: Insecure.RSA.PrivateKey) -> SSHAuthenticationMethod {
        .custom(CertificateRSASignerDelegate(username: username, key: key))
    }

    private static func publicKey<Algorithm: CertificateAlgorithm>(_ type: Algorithm.Type, _ certificate: SSHUserCertificate) -> NIOSSHPublicKey {
        NIOSSHPrivateKey(custom: CertificatePublicKeyAdapter<Algorithm>(certificate: certificate)).publicKey
    }
}

private final class CertificateAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let base: SSHAuthenticationMethod
    let certificate: SSHUserCertificate
    let rsaSHA256: Bool
    init(base: SSHAuthenticationMethod, certificate: SSHUserCertificate, rsaSHA256: Bool) {
        self.base = base; self.certificate = certificate; self.rsaSHA256 = rsaSHA256
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let pending = nextChallengePromise.futureResult.eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        pending.futureResult.flatMapThrowing { offer in
            guard let offer else { throw SSHError.authenticationFailed }
            return try SSHCertificateAuthentication.offer(offer, certificate: self.certificate, rsaSHA256: self.rsaSHA256)
        }.map { Optional($0) }.cascade(to: nextChallengePromise)
        base.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: pending)
    }
}

private final class CertificateRSASignerDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPrivateKey
    private var offered = false
    init(username: String, key: Insecure.RSA.PrivateKey) {
        self.username = username; self.key = NIOSSHPrivateKey(custom: CertificateRSA512Signer(key: key))
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else { nextChallengePromise.fail(SSHError.authenticationFailed); return }
        offered = true
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
    }
}

private struct CertificateRSA512Signer: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "rsa-sha2-512"
    let key: Insecure.RSA.PrivateKey
    var publicKey: NIOSSHPublicKeyProtocol { key.publicKey }
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        CertificateRSA512Signature(rawRepresentation: try key.signatureSHA512(for: data))
    }
}

private struct CertificateRSA512Signature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "rsa-sha2-512"
    let rawRepresentation: Data
    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation)
    }
    static func read(from buffer: inout ByteBuffer) throws -> Self { throw SSHCertificateError.unsupportedKey }
}

private protocol CertificateAlgorithm { static var name: String { get } }
private enum CertEd25519: CertificateAlgorithm { static let name = "ssh-ed25519-cert-v01@openssh.com" }
private enum CertP256: CertificateAlgorithm { static let name = "ecdsa-sha2-nistp256-cert-v01@openssh.com" }
private enum CertP384: CertificateAlgorithm { static let name = "ecdsa-sha2-nistp384-cert-v01@openssh.com" }
private enum CertP521: CertificateAlgorithm { static let name = "ecdsa-sha2-nistp521-cert-v01@openssh.com" }
private enum CertRSA512: CertificateAlgorithm { static let name = "rsa-sha2-512-cert-v01@openssh.com" }
private enum CertRSA256: CertificateAlgorithm { static let name = "rsa-sha2-256-cert-v01@openssh.com" }

/// NIOSSH constructs custom public keys through this public adapter API. Only its
/// public key is used; the authentication offer retains the real private key/agent signer.
private struct CertificatePublicKeyAdapter<Algorithm: CertificateAlgorithm>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Algorithm.name }
    let certificate: SSHUserCertificate
    var publicKey: NIOSSHPublicKeyProtocol { CertificatePublicKey<Algorithm>(certificate: certificate) }
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol { throw SSHCertificateError.unsupportedKey }
}

/// Outbound user-authentication adapter only; never registered as a host-key parser.
private struct CertificatePublicKey<Algorithm: CertificateAlgorithm>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Algorithm.name }
    let certificate: SSHUserCertificate
    var rawRepresentation: Data { Data(certificate.blob.dropFirst(4 + certificate.algorithm.utf8.count)) }
    func write(to buffer: inout ByteBuffer) -> Int {
        let start = buffer.writerIndex
        if Algorithm.name != certificate.algorithm {
            // RSA's requested digest and the signed certificate's key-type field are distinct.
            var prefix = AgentWire(); prefix.append(Algorithm.name)
            let index = start - prefix.data.count
            if index >= buffer.readerIndex, buffer.getBytes(at: index, length: prefix.data.count) == Array(prefix.data) {
                buffer.moveWriterIndex(to: index)
                buffer.writeBytes(certificate.blob)
                return buffer.writerIndex - start
            }
        }
        return buffer.writeBytes(rawRepresentation)
    }
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }
    static func read(from buffer: inout ByteBuffer) throws -> Self { throw SSHCertificateError.unsupportedKey }
}
