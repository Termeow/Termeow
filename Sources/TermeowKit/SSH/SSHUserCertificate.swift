import Crypto
import Darwin
import Foundation

public enum SSHCertificateError: Error, Equatable, Sendable, LocalizedError {
    case missingFile, unreadableFile, invalidFormat, unsupportedKey, invalidSignature
    case notUserCertificate, notYetValid, expired, keyMismatch, invalidAuthentication

    public var errorDescription: String? {
        switch self {
        case .missingFile: "Choose an OpenSSH user certificate file."
        case .unreadableFile: "The SSH certificate file could not be read. Choose it again."
        case .invalidFormat: "The file is not a valid OpenSSH certificate. Choose a single -cert.pub file, not a private key or an X.509 certificate."
        case .unsupportedKey: "This certificate or its CA uses an unsupported key. Use Ed25519, RSA (2048-8192 bits, SHA-2), or ECDSA P-256/P-384/P-521."
        case .invalidSignature: "The SSH certificate signature is invalid. The certificate may have been altered."
        case .notUserCertificate: "This is a host certificate. A user certificate is required for login."
        case .notYetValid: "The SSH user certificate is not valid yet. Check its validity period and your system clock."
        case .expired: "The SSH user certificate has expired. Renew it and reconnect."
        case .keyMismatch: "The SSH certificate does not match the selected private key or agent identity."
        case .invalidAuthentication: "An SSH user certificate requires Private Key or SSH Agent authentication."
        }
    }
}

public struct SSHCertificateConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var bookmark: Data?
    public var fileName: String

    public init(enabled: Bool = false, bookmark: Data? = nil, fileName: String = "") {
        self.enabled = enabled; self.bookmark = bookmark; self.fileName = fileName
    }

    /// Resolve the bookmark and read on every connection so certificate renewal needs no re-import.
    public func load() throws -> SSHUserCertificate {
        guard let bookmark else { throw SSHCertificateError.missingFile }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            return try SSHUserCertificate.load(from: url)
        } catch let error as SSHCertificateError { throw error }
        catch { throw SSHCertificateError.unreadableFile }
    }
}

/// An immutable, bounded parse of the original signed OpenSSH v01 wire representation.
/// Local signature validation checks integrity, not whether a server trusts this CA.
public struct SSHUserCertificate: Sendable, Equatable {
    public static let maximumBlobSize = 65_536
    public let blob: Data
    public let algorithm: String
    public let publicKey: SSHAgentIdentity
    public let authority: SSHAgentIdentity
    public let serial: UInt64
    public let keyID: String
    public let principals: [String]
    public let validAfter: UInt64
    public let validBefore: UInt64
    public let criticalOptions: [String: Data]
    public let extensions: [String: Data]

    public var fingerprint: String { "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "") }

    public static func load(from url: URL) throws -> Self {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.isFileURL else { throw SSHCertificateError.unreadableFile }
            // Check the opened descriptor, not a path that could be replaced by a FIFO.
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
            }
            guard descriptor >= 0 else { throw SSHCertificateError.unreadableFile }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw SSHCertificateError.unreadableFile }
            let contents = try handle.read(upToCount: maximumBlobSize * 2 + 1) ?? Data()
            guard contents.count <= maximumBlobSize * 2, let text = String(data: contents, encoding: .utf8) else {
                throw SSHCertificateError.invalidFormat
            }
            return try Self(text: text)
        } catch let error as SSHCertificateError { throw error }
        catch { throw SSHCertificateError.unreadableFile }
    }

    public init(text: String) throws {
        guard text.utf8.count <= Self.maximumBlobSize * 2 else { throw SSHCertificateError.invalidFormat }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.count == 1 else { throw SSHCertificateError.invalidFormat }
        let fields = lines[0].split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { throw SSHCertificateError.invalidFormat }
        try self.init(blob: blob)
        guard fields[0] == algorithm else { throw SSHCertificateError.invalidFormat }
    }

    public init(blob: Data) throws {
        guard !blob.isEmpty, blob.count <= Self.maximumBlobSize else { throw SSHCertificateError.invalidFormat }
        do {
            var reader = CertificateWire(blob)
            let algorithm = try reader.string(limit: 128)
            guard algorithm.contains("-cert-") else { throw SSHCertificateError.invalidFormat }
            guard let base = Self.baseAlgorithm(algorithm) else { throw SSHCertificateError.unsupportedKey }
            _ = try reader.bytes(limit: 4096) // Nonce remains covered by the original signature.
            var subject = AgentWire(); subject.append(base)
            if base == "ssh-ed25519" {
                subject.append(try reader.bytes(limit: 32))
            } else if base == "ssh-rsa" {
                subject.append(try reader.bytes(limit: 9)); subject.append(try reader.bytes(limit: 1025))
            } else {
                subject.append(try reader.bytes(limit: 16)); subject.append(try reader.bytes(limit: 133))
            }
            let publicKey = try SSHAgentIdentity(blob: subject.data, comment: "")
            guard publicKey.isSupported else { throw SSHCertificateError.unsupportedKey }
            let serial = try reader.uint64()
            let role = try reader.uint32()
            let keyID = try reader.string(limit: 4096)
            var names = CertificateWire(try reader.bytes(limit: 16_384))
            var principals: [String] = []
            while !names.isEmpty {
                guard principals.count < 256 else { throw SSHCertificateError.invalidFormat }
                principals.append(try names.string(limit: 1024))
            }
            let validAfter = try reader.uint64()
            let validBefore = try reader.uint64()
            let options = try Self.readOptions(reader.bytes(limit: 16_384))
            let extensions = try Self.readOptions(reader.bytes(limit: 16_384))
            _ = try reader.bytes(limit: 4096) // Reserved bytes must not be reserialized or stripped.
            let authority = try SSHAgentIdentity(blob: reader.bytes(limit: 16_384), comment: "")
            guard authority.isSupported else { throw SSHCertificateError.unsupportedKey }
            let signedBytes = Data(blob.prefix(reader.offset))
            var signature = CertificateWire(try reader.bytes(limit: 16_384))
            let signatureAlgorithm = try signature.string(limit: 128)
            let signatureBytes = try signature.bytes(limit: 8192)
            guard reader.isEmpty, signature.isEmpty else { throw SSHCertificateError.invalidFormat }
            guard try SSHAgentKeyMaterial(identity: authority).verify(signatureBytes, algorithm: signatureAlgorithm, message: signedBytes) else {
                throw SSHCertificateError.invalidSignature
            }
            guard role == 1 else { throw SSHCertificateError.notUserCertificate }
            guard validAfter < validBefore else { throw SSHCertificateError.invalidFormat }
            self.blob = blob; self.algorithm = algorithm; self.publicKey = publicKey; self.authority = authority
            self.serial = serial; self.keyID = keyID; self.principals = principals
            self.validAfter = validAfter; self.validBefore = validBefore
            self.criticalOptions = options; self.extensions = extensions
        } catch let error as SSHCertificateError { throw error }
        catch SSHAgentError.unsupportedKey { throw SSHCertificateError.unsupportedKey }
        catch { throw SSHCertificateError.invalidFormat }
    }

    public func validate(at date: Date = Date(), matching publicKeyBlob: Data? = nil) throws {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) else { throw SSHCertificateError.notYetValid }
        let now = UInt64(seconds)
        guard now >= validAfter else { throw SSHCertificateError.notYetValid }
        guard now < validBefore else { throw SSHCertificateError.expired }
        if let publicKeyBlob, publicKeyBlob != publicKey.blob { throw SSHCertificateError.keyMismatch }
        // Principal mapping, CA trust, revocation and permission enforcement belong to the server.
    }

    private static func baseAlgorithm(_ algorithm: String) -> String? {
        let suffix = "-cert-v01@openssh.com"
        guard algorithm.hasSuffix(suffix) else { return nil }
        let base = String(algorithm.dropLast(suffix.count))
        return SSHAgentKeyMaterial.supportedAlgorithms.contains(base) ? base : nil
    }

    private static func readOptions(_ bytes: Data) throws -> [String: Data] {
        var reader = CertificateWire(bytes)
        var result: [String: Data] = [:]
        var previous: String?
        while !reader.isEmpty {
            let name = try reader.string(limit: 256)
            guard !name.isEmpty, result.count < 128, previous == nil || previous!.utf8.lexicographicallyPrecedes(name.utf8) else {
                throw SSHCertificateError.invalidFormat
            }
            result[name] = try reader.bytes(limit: 8192)
            previous = name
        }
        return result
    }
}

private struct CertificateWire {
    let data: Data
    private(set) var offset = 0
    init(_ data: Data) { self.data = Data(data) }
    var isEmpty: Bool { offset == data.count }
    mutating func uint32() throws -> UInt32 { UInt32(try integer(count: 4)) }
    mutating func uint64() throws -> UInt64 { try integer(count: 8) }
    private mutating func integer(count: Int) throws -> UInt64 {
        guard data.count - offset >= count else { throw SSHCertificateError.invalidFormat }
        var value: UInt64 = 0
        for byte in data[offset..<(offset + count)] { value = value << 8 | UInt64(byte) }
        offset += count
        return value
    }
    mutating func bytes(limit: Int) throws -> Data {
        let count = Int(try uint32())
        guard count <= limit, data.count - offset >= count else { throw SSHCertificateError.invalidFormat }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }
    mutating func string(limit: Int) throws -> String {
        guard let string = String(data: try bytes(limit: limit), encoding: .utf8) else { throw SSHCertificateError.invalidFormat }
        return string
    }
}
