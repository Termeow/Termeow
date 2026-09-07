import Foundation

enum PrivateKeyMaterial {
    struct RSAPEMKey {
        let pkcs1DER: Data
        let modulus: Data
        let publicExponent: Data
    }

    static func normalizedOpenSSHKey(from keyText: String) throws -> String {
        let normalized = normalizedPEM(keyText)

        if normalized.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
            return normalized
        }
        throw SSHError.invalidPrivateKey
    }

    static func rsaPEMKey(from keyText: String) throws -> RSAPEMKey? {
        let normalized = normalizedPEM(keyText)
        let pkcs1: Data
        if normalized.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") {
            pkcs1 = try decodePEM(normalized, label: "RSA PRIVATE KEY")
        } else if normalized.hasPrefix("-----BEGIN PRIVATE KEY-----") {
            let pkcs8 = try decodePEM(normalized, label: "PRIVATE KEY")
            pkcs1 = try rsaPKCS1Data(fromPKCS8: pkcs8)
        } else {
            return nil
        }
        let components = try rsaPKCS1Components(from: pkcs1)
        return RSAPEMKey(
            pkcs1DER: pkcs1,
            modulus: components.modulus,
            publicExponent: components.publicExponent
        )
    }

    private static func normalizedPEM(_ keyText: String) -> String {
        keyText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodePEM(_ pem: String, label: String) throws -> Data {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        guard pem.hasPrefix(begin), pem.hasSuffix(end) else {
            throw SSHError.invalidPrivateKey
        }
        let bodyStart = pem.index(pem.startIndex, offsetBy: begin.count)
        let bodyEnd = pem.index(pem.endIndex, offsetBy: -end.count)
        let body = pem[bodyStart ..< bodyEnd].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else {
            throw SSHError.invalidPrivateKey
        }
        return data
    }

    private static func rsaPKCS1Data(fromPKCS8 data: Data) throws -> Data {
        var outer = DERReader(data: data)
        var sequence = DERReader(data: try outer.read(tag: 0x30))
        _ = try sequence.read(tag: 0x02)
        _ = try sequence.read(tag: 0x30)
        return try sequence.read(tag: 0x04)
    }

    private static func rsaPKCS1Components(from data: Data) throws -> RSAComponents {
        var outer = DERReader(data: data)
        var sequence = DERReader(data: try outer.read(tag: 0x30))
        let version = try sequence.read(tag: 0x02)
        guard !version.isEmpty, version.allSatisfy({ $0 == 0 }) else {
            throw SSHError.invalidPrivateKey
        }

        let modulus = try sequence.readPositiveInteger()
        let publicExponent = try sequence.readPositiveInteger()
        _ = try sequence.readPositiveInteger()
        _ = try sequence.readPositiveInteger()
        _ = try sequence.readPositiveInteger()
        _ = try sequence.readPositiveInteger()
        _ = try sequence.readPositiveInteger()
        _ = try sequence.readPositiveInteger()
        return RSAComponents(
            modulus: modulus,
            publicExponent: publicExponent
        )
    }
}

private struct RSAComponents {
    let modulus: Data
    let publicExponent: Data
}

private struct DERReader {
    let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func read(tag expectedTag: UInt8) throws -> Data {
        guard offset < data.count, data[offset] == expectedTag else {
            throw SSHError.invalidPrivateKey
        }
        offset += 1
        let length = try readLength()
        guard length >= 0, offset <= data.count - length else {
            throw SSHError.invalidPrivateKey
        }
        let value = data[offset ..< offset + length]
        offset += length
        return Data(value)
    }

    mutating func readPositiveInteger() throws -> Data {
        var bytes = Array(try read(tag: 0x02))
        guard !bytes.isEmpty, bytes[0] & 0x80 == 0 else {
            throw SSHError.invalidPrivateKey
        }
        while bytes.count > 1, bytes[0] == 0, bytes[1] & 0x80 == 0 {
            bytes.removeFirst()
        }
        return Data(bytes)
    }

    private mutating func readLength() throws -> Int {
        guard offset < data.count else { throw SSHError.invalidPrivateKey }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7f)
        guard (1 ... 4).contains(byteCount), offset <= data.count - byteCount else {
            throw SSHError.invalidPrivateKey
        }
        var length = 0
        for _ in 0 ..< byteCount {
            guard length <= (Int.max >> 8) else { throw SSHError.invalidPrivateKey }
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }
}
