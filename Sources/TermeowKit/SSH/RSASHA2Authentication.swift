@preconcurrency import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security

enum RSASHA2Authentication {
    static func method(username: String, key: PrivateKeyMaterial.RSAPEMKey) throws -> SSHAuthenticationMethod {
        let privateKey = try RSASHA512PrivateKey(key: key)
        return .custom(SingleKeyAuthenticationDelegate(username: username, privateKey: privateKey))
    }
}

private final class SingleKeyAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private let lock = NSLock()
    private var offered = false

    init(username: String, privateKey: RSASHA512PrivateKey) {
        self.username = username
        self.privateKey = NIOSSHPrivateKey(custom: privateKey)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHError.authenticationFailed)
            return
        }
        lock.lock()
        let shouldOffer = !offered
        offered = true
        lock.unlock()
        guard shouldOffer else {
            nextChallengePromise.fail(SSHError.authenticationFailed)
            return
        }
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}

private final class RSASHA512PrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static let keyPrefix = "rsa-sha2-512"

    let publicKey: NIOSSHPublicKeyProtocol
    private let key: SecKey

    init(key material: PrivateKeyMaterial.RSAPEMKey) throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(material.pkcs1DER as CFData, attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? SSHError.invalidPrivateKey
        }
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw SSHError.invalidPrivateKey
        }
        self.key = key
        self.publicKey = RSASHA512PublicKey(
            key: publicKey,
            exponent: material.publicExponent,
            modulus: material.modulus
        )
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA512
        guard SecKeyIsAlgorithmSupported(key, .sign, algorithm) else {
            throw SSHError.unsupportedAlgorithm
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, Data(data) as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? SSHError.authenticationFailed
        }
        return RSASHA512Signature(rawRepresentation: signature)
    }
}

private final class RSASHA512PublicKey: NIOSSHPublicKeyProtocol, @unchecked Sendable {
    static let publicKeyPrefix = "rsa-sha2-512"

    let rawRepresentation: Data
    private let key: SecKey

    init(key: SecKey, exponent: Data, modulus: Data) {
        self.key = key
        var writer = RSAWireWriter()
        writer.appendMPInt(exponent)
        writer.appendMPInt(modulus)
        rawRepresentation = writer.data
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? RSASHA512Signature else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA512,
            Data(data) as CFData,
            signature.rawRepresentation as CFData,
            &error
        )
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512PublicKey {
        throw SSHError.unsupportedAlgorithm
    }
}

private struct RSASHA512Signature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "rsa-sha2-512"

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = buffer.writeInteger(UInt32(rawRepresentation.count))
        written += buffer.writeBytes(rawRepresentation)
        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSASHA512Signature {
        guard let length = buffer.readInteger(as: UInt32.self),
              let bytes = buffer.readBytes(length: Int(length)) else {
            throw SSHError.invalidPrivateKey
        }
        return RSASHA512Signature(rawRepresentation: Data(bytes))
    }
}

private struct RSAWireWriter {
    var data = Data()

    mutating func appendMPInt(_ value: Data) {
        var bytes = Array(value)
        while bytes.count > 1, bytes[0] == 0, bytes[1] & 0x80 == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        append(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    private mutating func append(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}
