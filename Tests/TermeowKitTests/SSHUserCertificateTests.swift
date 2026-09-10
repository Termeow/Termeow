@preconcurrency import Citadel
import Crypto
import Darwin
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Testing
@testable import TermeowKit

@Suite struct SSHUserCertificateTests {
    @Test func parsesSignedMetadataWithoutChangingReservedBytes() throws {
        let fixture = try CertificateTestData(reserved: Data([0, 255, 7]), principals: ["production-access", "audit"])
        let certificate = try SSHUserCertificate(blob: fixture.blob)
        #expect(certificate.blob == fixture.blob)
        #expect(certificate.serial == 42)
        #expect(certificate.keyID == "Test certificate")
        #expect(certificate.principals == ["production-access", "audit"])
        #expect(certificate.publicKey.blob == (try edIdentity(fixture.key).blob))
        #expect(certificate.authority.blob == (try edIdentity(fixture.ca).blob))
        #expect(certificate.fingerprint.hasPrefix("SHA256:"))
        #expect(certificate.extensions.keys.sorted() == ["permit-port-forwarding", "permit-pty"])
        try certificate.validate(at: Date(timeIntervalSince1970: 150), matching: certificate.publicKey.blob)
        #expect(try SSHUserCertificate(text: "# Comment\n\(fixture.text)\r\n") == certificate)
    }

    @Test func rejectsModifiedSignaturesHostCertificatesAndMismatchedKeys() throws {
        var blob = try CertificateTestData().blob
        blob[blob.count - 1] ^= 1
        #expect(throws: SSHCertificateError.invalidSignature) { try SSHUserCertificate(blob: blob) }
        #expect(throws: SSHCertificateError.notUserCertificate) { try SSHUserCertificate(blob: CertificateTestData(role: 2).blob) }
        let certificate = try SSHUserCertificate(blob: CertificateTestData().blob)
        #expect(throws: SSHCertificateError.keyMismatch) {
            try certificate.validate(at: Date(timeIntervalSince1970: 150), matching: edIdentity(Curve25519.Signing.PrivateKey()).blob)
        }
    }

    @Test func validatesInclusiveStartExclusiveEndAndUnlimitedExpiry() throws {
        let certificate = try SSHUserCertificate(blob: CertificateTestData().blob)
        #expect(throws: SSHCertificateError.notYetValid) { try certificate.validate(at: Date(timeIntervalSince1970: 99)) }
        try certificate.validate(at: Date(timeIntervalSince1970: 100))
        try certificate.validate(at: Date(timeIntervalSince1970: 199.9))
        #expect(throws: SSHCertificateError.expired) { try certificate.validate(at: Date(timeIntervalSince1970: 200)) }
        let unlimited = try SSHUserCertificate(blob: CertificateTestData(after: 0, before: .max).blob)
        try unlimited.validate()
        #expect(throws: SSHCertificateError.invalidFormat) { try SSHUserCertificate(blob: CertificateTestData(after: 200, before: 100).blob) }
        #expect(throws: SSHCertificateError.notYetValid) { try unlimited.validate(at: Date(timeIntervalSince1970: -1)) }
    }

    @Test func boundsMalformedInputsAndRejectsAmbiguousEncoding() throws {
        let fixture = try CertificateTestData()
        for count in [0, 1, 4, 20, fixture.blob.count - 1] {
            #expect(throws: SSHCertificateError.self) { try SSHUserCertificate(blob: Data(fixture.blob.prefix(count))) }
        }
        #expect(throws: SSHCertificateError.invalidFormat) { try SSHUserCertificate(blob: fixture.blob + Data([0])) }
        #expect(throws: SSHCertificateError.invalidFormat) { try SSHUserCertificate(blob: Data(repeating: 0, count: 65_537)) }
        #expect(throws: SSHCertificateError.invalidFormat) { try SSHUserCertificate(text: fixture.text + "\n" + fixture.text) }
        #expect(throws: SSHCertificateError.invalidFormat) {
            try SSHUserCertificate(text: "ssh-rsa-cert-v01@openssh.com \(fixture.blob.base64EncodedString())")
        }
        #expect(throws: SSHCertificateError.invalidFormat) { try SSHUserCertificate(text: "ssh-ed25519-cert-v01@openssh.com !invalid!") }
        #expect(throws: SSHCertificateError.invalidFormat) { try SSHUserCertificate(text: edIdentity(fixture.key).authorizedKey) }
        var malformed = fixture.blob
        malformed.replaceSubrange(0..<4, with: [255, 255, 255, 255])
        #expect(throws: SSHCertificateError.invalidFormat) { try SSHUserCertificate(blob: malformed) }
    }

    @Test func retainsUnknownOptionsButRejectsDuplicateAndUnsortedMaps() throws {
        // The remote server, not this client, enforces critical options and principal mapping.
        let options: [(String, Data)] = [("force-command", Data([0, 0, 0, 4]) + Data("true".utf8)), ("future@example.test", Data([42]))]
        let certificate = try SSHUserCertificate(blob: CertificateTestData(after: 0, before: .max, options: options).blob)
        try certificate.validate()
        #expect(certificate.criticalOptions["future@example.test"] == Data([42]))
        #expect(throws: SSHCertificateError.invalidFormat) {
            try SSHUserCertificate(blob: CertificateTestData(options: [("x", Data()), ("x", Data())]).blob)
        }
        #expect(throws: SSHCertificateError.invalidFormat) {
            try SSHUserCertificate(blob: CertificateTestData(options: [("z", Data()), ("a", Data())]).blob)
        }
    }

    @Test func offersTheExactCertificateUsingTheOriginalSigner() throws {
        let fixture = try CertificateTestData(after: 0, before: .max)
        let certificate = try SSHUserCertificate(blob: fixture.blob)
        let original = NIOSSHUserAuthenticationOffer(username: "not-the-principal", serviceName: "ssh-connection",
                                                   offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: fixture.key))))
        let offered = try SSHCertificateAuthentication.offer(original, certificate: certificate)
        guard case .privateKey(let key) = offered.offer else { Issue.record("Expected certificate public-key authentication"); return }
        var encoded = ByteBuffer(); key.publicKey.write(to: &encoded)
        #expect(Data(encoded.readableBytesView) == fixture.blob)
        #expect(offered.username == "not-the-principal")
        let digest = SHA256.hash(data: Data("Real signing key remains attached".utf8))
        #expect(key.privateKey.publicKey.isValidSignature(try key.privateKey.sign(digest: digest), for: digest))
        let password = NIOSSHUserAuthenticationOffer(username: "test", serviceName: "ssh-connection", offer: .password(.init(password: "test-only")))
        #expect(throws: SSHCertificateError.invalidAuthentication) { try SSHCertificateAuthentication.offer(password, certificate: certificate) }
    }

    @Test func certificateSettingsRoundTripWithoutEmbeddingKeys() throws {
        var profile = SessionProfile(name: "Certificate", host: "example.test", username: "test", authMethod: .privateKey)
        profile.certificate = SSHCertificateConfiguration(enabled: true, bookmark: Data([1, 2, 3]), fileName: "identity-cert.pub")
        #expect(profile.isValidForSaving)
        let encoded = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(SessionProfile.self, from: encoded) == profile)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "certificate")
        #expect(try JSONDecoder().decode(SessionProfile.self, from: JSONSerialization.data(withJSONObject: legacy)).certificate == SSHCertificateConfiguration())
        profile.authMethod = .password
        #expect(!profile.isValidForSaving)
        profile.certificate.enabled = false
        #expect(profile.isValidForSaving)
        profile.authMethod = .privateKey; profile.certificate.enabled = true; profile.certificate.bookmark = nil
        #expect(!profile.isValidForSaving)
    }

    @Test func agentCanSignCertificateSizedPayloadsButRejectsOversizedRequests() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let identity = try edIdentity(key)
        let payload = Data(repeating: 42, count: 131_072)
        try await withMockAgent(reply: { bytes in
            var request = AgentWire(bytes)
            guard (try? request.byte()) == 13, (try? request.bytes()) == identity.blob,
                  let message = try? request.bytes(), (try? request.uint32()) == 0, request.isEmpty,
                  let signature = try? key.signature(for: message) else { return agentFrame(Data([5])) }
            return agentSignatureFrame(algorithm: "ssh-ed25519", signature: signature)
        }) { agent in
            let signer = AgentSigner(identity: identity, path: agent.path, access: SSHAgentAccess(), timeout: 2)
            let signature = try await Task.detached { try signer.sign(payload, algorithm: "ssh-ed25519") }.value
            #expect(key.publicKey.isValidSignature(signature, for: payload))
            #expect(throws: SSHAgentError.invalidResponse) { try signer.sign(payload + Data([0]), algorithm: "ssh-ed25519") }
            #expect(agent.requests.values.count == 1)
        }
    }

    @Test func readsRenewedFilesAndRejectsDirectoriesOrMissingBookmarks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termeow-certificate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("user-cert.pub")
        let old = try CertificateTestData()
        try old.text.write(to: path, atomically: true, encoding: .utf8)
        let configuration = SSHCertificateConfiguration(enabled: true, bookmark: try path.bookmarkData(options: .withSecurityScope), fileName: path.lastPathComponent)
        #expect(try configuration.load().blob == old.blob)
        let renewed = try CertificateTestData(after: 0, before: .max)
        try renewed.text.write(to: path, atomically: true, encoding: .utf8)
        #expect(try configuration.load().blob == renewed.blob)
        #expect(throws: SSHCertificateError.unreadableFile) { try SSHUserCertificate.load(from: directory) }
        let pipe = directory.appendingPathComponent("not-a-certificate")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: SSHCertificateError.unreadableFile) { try SSHUserCertificate.load(from: pipe) }
        let oversized = directory.appendingPathComponent("oversized-cert.pub")
        try Data(repeating: 65, count: SSHUserCertificate.maximumBlobSize * 2 + 1).write(to: oversized)
        #expect(throws: SSHCertificateError.invalidFormat) { try SSHUserCertificate.load(from: oversized) }
        #expect(throws: SSHCertificateError.missingFile) { try SSHCertificateConfiguration(enabled: true).load() }
        try FileManager.default.removeItem(at: path)
        #expect(throws: SSHCertificateError.unreadableFile) { try configuration.load() }
    }
}

private struct CertificateTestData {
    let key = Curve25519.Signing.PrivateKey()
    let ca = Curve25519.Signing.PrivateKey()
    let blob: Data
    var text: String { "ssh-ed25519-cert-v01@openssh.com \(blob.base64EncodedString()) fixture" }
    init(role: UInt32 = 1, after: UInt64 = 100, before: UInt64 = 200, reserved: Data = Data(),
         principals: [String] = ["test"], options: [(String, Data)] = []) throws {
        var wire = AgentWire()
        wire.append("ssh-ed25519-cert-v01@openssh.com"); wire.append(Data(repeating: 42, count: 32))
        wire.append(key.publicKey.rawRepresentation)
        wire.append(UInt32(0)); wire.append(UInt32(42)); wire.append(role); wire.append("Test certificate")
        var names = AgentWire(); principals.forEach { names.append($0) }; wire.append(names.data)
        for value in [after, before] { wire.append(UInt32(value >> 32)); wire.append(UInt32(truncatingIfNeeded: value)) }
        var critical = AgentWire(); options.forEach { critical.append($0.0); critical.append($0.1) }; wire.append(critical.data)
        var permissions = AgentWire()
        for name in ["permit-port-forwarding", "permit-pty"] { permissions.append(name); permissions.append(Data()) }
        wire.append(permissions.data); wire.append(reserved); wire.append(try edIdentity(ca).blob)
        var signature = AgentWire(); signature.append("ssh-ed25519"); signature.append(try ca.signature(for: wire.data))
        wire.append(signature.data); blob = wire.data
    }
}
