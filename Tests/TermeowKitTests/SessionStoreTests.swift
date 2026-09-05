import Foundation
import Testing
@testable import TermeowKit

@Test func sessionJSONRoundTripOmitsSecrets() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("termeow-session-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let profile = SessionProfile(
        name: "lab",
        host: "example.com",
        username: "alice",
        credentialID: UUID()
    )
    let store = SessionStore(fileURL: url)
    try store.save([profile])
    let loaded = try store.load()
    #expect(loaded == [profile])

    let raw = try String(contentsOf: url, encoding: .utf8)
    #expect(!raw.contains("passphrase"))
    #expect(!raw.contains("BEGIN OPENSSH PRIVATE KEY"))
    #expect(!raw.contains("BEGIN RSA PRIVATE KEY"))
}

@Test func hostKeyStoreUnknownMatchMismatch() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("termeow-hostkeys-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HostKeyStore(fileURL: url)

    let first = HostKeyRecord(
        host: "example.com",
        port: 22,
        algorithm: "ssh-ed25519",
        fingerprintSHA256: "AAAA",
        publicKeyBase64: "key-a"
    )
    #expect(try store.check(presented: first) == .unknown(first))
    try store.upsert(first)
    #expect(try store.check(presented: first) == .match)

    let changed = HostKeyRecord(
        host: "example.com",
        port: 22,
        algorithm: "ssh-ed25519",
        fingerprintSHA256: "BBBB",
        publicKeyBase64: "key-b"
    )
    guard case .mismatch(let stored, let presented) = try store.check(presented: changed) else {
        Issue.record("expected host key mismatch")
        return
    }
    #expect(stored.publicKeyBase64 == first.publicKeyBase64)
    #expect(presented.publicKeyBase64 == changed.publicKeyBase64)
}

@Test func sessionProfileValidationRejectsInvalidConnectionSettings() {
    var profile = SessionProfile(name: "lab", host: "example.com", username: "alice")
    #expect(profile.isValidForSaving)

    profile.port = 0
    #expect(!profile.isValidForSaving)
    profile.port = 65_536
    #expect(!profile.isValidForSaving)
    profile.port = 22

    profile.timeoutSeconds = 0
    #expect(!profile.isValidForSaving)
    profile.timeoutSeconds = 30

    profile.keepAliveSeconds = -1
    #expect(!profile.isValidForSaving)
    profile.keepAliveSeconds = 0
    #expect(profile.isValidForSaving)

    profile.host = "   "
    #expect(!profile.isValidForSaving)
    profile.host = "example.com"
    profile.username = "\n"
    #expect(!profile.isValidForSaving)
}
