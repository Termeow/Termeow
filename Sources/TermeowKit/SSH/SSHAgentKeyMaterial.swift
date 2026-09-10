import Crypto
import Foundation
import Security

/// Public material only. Validate agent output locally before handing a signature to SSH.
enum SSHAgentKeyMaterial {
    static let supportedAlgorithms: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]

    case ed25519(Curve25519.Signing.PublicKey)
    case rsa(SecKey)
    case p256(P256.Signing.PublicKey)
    case p384(P384.Signing.PublicKey)
    case p521(P521.Signing.PublicKey)

    init(identity: SSHAgentIdentity) throws {
        var wire = AgentWire(identity.blob)
        _ = try wire.string()
        do {
            switch identity.algorithm {
            case "ssh-ed25519":
                self = .ed25519(try Curve25519.Signing.PublicKey(rawRepresentation: wire.bytes(limit: 32)))
            case "ssh-rsa":
                let exponent = try Self.positiveInteger(wire.bytes(limit: 9), limit: 8)
                let modulus = try Self.positiveInteger(wire.bytes(limit: 1025), limit: 1024)
                guard modulus.last! & 1 == 1,
                      exponent.last! & 1 == 1, exponent.count > 1 || exponent[0] >= 3 else {
                    throw SSHAgentError.invalidResponse
                }
                guard modulus.count >= 256, modulus.count > 256 || modulus[0] & 0x80 != 0 else {
                    throw SSHAgentError.unsupportedKey
                }
                let der = Self.der(0x30, Self.derInteger(modulus) + Self.derInteger(exponent))
                let attributes: [String: Any] = [
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                ]
                guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else {
                    throw SSHAgentError.invalidResponse
                }
                self = .rsa(key)
            case "ecdsa-sha2-nistp256":
                guard try wire.string() == "nistp256" else { throw SSHAgentError.invalidResponse }
                self = .p256(try P256.Signing.PublicKey(x963Representation: wire.bytes(limit: 65)))
            case "ecdsa-sha2-nistp384":
                guard try wire.string() == "nistp384" else { throw SSHAgentError.invalidResponse }
                self = .p384(try P384.Signing.PublicKey(x963Representation: wire.bytes(limit: 97)))
            case "ecdsa-sha2-nistp521":
                guard try wire.string() == "nistp521" else { throw SSHAgentError.invalidResponse }
                self = .p521(try P521.Signing.PublicKey(x963Representation: wire.bytes(limit: 133)))
            default: throw SSHAgentError.unsupportedKey
            }
            guard wire.isEmpty else { throw SSHAgentError.invalidResponse }
        } catch let error as SSHAgentError { throw error }
        catch { throw SSHAgentError.invalidResponse }
    }

    func verify(_ signature: Data, algorithm: String, message: Data) -> Bool {
        do {
            switch self {
            case .ed25519(let key):
                return algorithm == "ssh-ed25519" && key.isValidSignature(signature, for: message)
            case .rsa(let key):
                let digest: SecKeyAlgorithm
                switch algorithm {
                case "rsa-sha2-512": digest = .rsaSignatureMessagePKCS1v15SHA512
                case "rsa-sha2-256": digest = .rsaSignatureMessagePKCS1v15SHA256
                default: return false
                }
                let width = SecKeyGetBlockSize(key)
                guard !signature.isEmpty, signature.count <= width else { return false }
                // RFC 8332 permits agents/servers to omit leading zero octets.
                let padded = Data(repeating: 0, count: width - signature.count) + signature
                return SecKeyVerifySignature(key, digest, message as CFData, padded as CFData, nil)
            case .p256(let key):
                guard algorithm == "ecdsa-sha2-nistp256" else { return false }
                return try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: Self.ecdsaRaw(signature, width: 32)), for: message)
            case .p384(let key):
                guard algorithm == "ecdsa-sha2-nistp384" else { return false }
                return try key.isValidSignature(P384.Signing.ECDSASignature(rawRepresentation: Self.ecdsaRaw(signature, width: 48)), for: message)
            case .p521(let key):
                guard algorithm == "ecdsa-sha2-nistp521" else { return false }
                return try key.isValidSignature(P521.Signing.ECDSASignature(rawRepresentation: Self.ecdsaRaw(signature, width: 66)), for: message)
            }
        } catch { return false }
    }

    private static func ecdsaRaw(_ signature: Data, width: Int) throws -> Data {
        var wire = AgentWire(signature)
        let r = try positiveInteger(wire.bytes(limit: width + 1), limit: width)
        let s = try positiveInteger(wire.bytes(limit: width + 1), limit: width)
        guard wire.isEmpty else { throw SSHAgentError.invalidSignature }
        return Data(repeating: 0, count: width - r.count) + r + Data(repeating: 0, count: width - s.count) + s
    }

    private static func positiveInteger(_ bytes: Data, limit: Int) throws -> Data {
        guard let first = bytes.first, first & 0x80 == 0 else { throw SSHAgentError.invalidResponse }
        var value = bytes
        if first == 0 {
            guard bytes.count > 1, bytes[1] & 0x80 != 0 else { throw SSHAgentError.invalidResponse }
            value = Data(bytes.dropFirst())
        }
        guard value.count <= limit else { throw SSHAgentError.invalidResponse }
        return value
    }

    private static func derInteger(_ bytes: Data) -> Data {
        der(0x02, bytes.first! & 0x80 != 0 ? Data([0]) + bytes : bytes)
    }

    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var result = Data([tag])
        if bytes.count < 128 { result.append(UInt8(bytes.count)) }
        else {
            var length = bytes.count
            var encoded: [UInt8] = []
            while length > 0 { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 }
            result.append(0x80 | UInt8(encoded.count)); result.append(contentsOf: encoded)
        }
        result.append(bytes)
        return result
    }
}
