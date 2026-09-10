import Foundation
import Testing
@testable import TermeowKit

private func routeProfile(_ name: String, via: SessionProfile? = nil) -> SessionProfile {
    SessionProfile(name: name, host: "\(name).example.test", username: "tester", jumpHostID: via?.id)
}

@Test func jumpRouteResolvesOutermostFirst() throws {
    let outer = routeProfile("outer")
    let inner = routeProfile("inner", via: outer)
    let target = routeProfile("target", via: inner)
    #expect(try SSHConnectionRoute.resolve(destination: target, profiles: [target, inner, outer]) == [outer, inner, target])
    #expect(try SSHConnectionRoute.resolve(destination: outer, profiles: []) == [outer])
}

@Test func jumpRouteRejectsCyclesAndMissingReferences() {
    var first = routeProfile("first")
    let second = routeProfile("second", via: first)
    first.jumpHostID = second.id
    #expect(throws: SSHRouteError.cycle) {
        try SSHConnectionRoute.resolve(destination: first, profiles: [first, second])
    }
    first.jumpHostID = first.id
    #expect(throws: SSHRouteError.cycle) {
        try SSHConnectionRoute.resolve(destination: first, profiles: [first])
    }
    #expect(throws: SSHRouteError.missingJumpHost) {
        try SSHConnectionRoute.resolve(destination: second, profiles: [])
    }
}

@Test func jumpRouteLimitsDepthAndValidatesEveryHop() throws {
    var profiles = [routeProfile("outer")]
    for index in 1...8 { profiles.append(routeProfile("hop\(index)", via: profiles.last)) }
    #expect(try SSHConnectionRoute.resolve(destination: profiles.last!, profiles: profiles).count == 9)
    let excessive = routeProfile("excessive", via: profiles.last)
    #expect(throws: SSHRouteError.tooManyHops) {
        try SSHConnectionRoute.resolve(destination: excessive, profiles: profiles)
    }
    profiles[0].port = 0
    #expect(throws: SSHRouteError.invalidProfile) {
        try SSHConnectionRoute.resolve(destination: profiles.last!, profiles: profiles)
    }
}

@Test func preparedJumpRouteCannotOmitOrReorderHops() throws {
    let outer = routeProfile("outer")
    let inner = routeProfile("inner", via: outer)
    let target = routeProfile("target", via: inner)
    let hops = [outer, inner].map { SSHConnectionHop(profile: $0, secret: "test-only") }
    try SSHConnectionRoute.validatePreparedRoute(jumpHosts: hops, destination: target)
    #expect(throws: SSHRouteError.missingJumpHost) {
        try SSHConnectionRoute.validatePreparedRoute(jumpHosts: [], destination: target)
    }
    #expect(throws: SSHRouteError.cycle) {
        try SSHConnectionRoute.validatePreparedRoute(jumpHosts: hops.reversed(), destination: target)
    }
    #expect(throws: SSHRouteError.cycle) {
        try SSHConnectionRoute.validatePreparedRoute(jumpHosts: hops, destination: outer)
    }
}

@Test func jumpHostReferenceRoundTripsAndLegacySessionsRemainDirect() throws {
    let profile = routeProfile("target", via: routeProfile("outer"))
    let data = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(SessionProfile.self, from: data) == profile)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "jumpHostID")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(SessionProfile.self, from: legacy).jumpHostID == nil)
    #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
}

@Test func incompleteJumpRouteFailsBeforeNetworkOrPrompt() async {
    let target = routeProfile("target", via: routeProfile("missing"))
    await #expect(throws: SSHError.invalidJumpRoute) {
        _ = try await CitadelConnectionFactory.connect(
            profile: target, secret: "test-only", hostKeyStore: isolatedRouteHostKeyStore()
        ) { _ in Issue.record("Invalid routes must not reach host-key verification"); return .cancel }
    }
}

@Test func missingJumpCredentialIdentifiesTheHopBeforeConnecting() async {
    let outer = routeProfile("outer")
    let target = routeProfile("target", via: outer)
    await #expect(throws: SSHError.jumpHostFailed("outer", .missingCredential)) {
        _ = try await CitadelConnectionFactory.connect(
            profile: target, secret: "test-only", hostKeyStore: isolatedRouteHostKeyStore(),
            jumpHosts: [SSHConnectionHop(profile: outer, secret: "")]
        ) { _ in Issue.record("Missing credentials must not reach the network"); return .cancel }
    }
}

func isolatedRouteHostKeyStore() -> HostKeyStore {
    HostKeyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("termeow-route-\(UUID()).json"))
}

@Test func closingRouteDiscardsLateHostKeyApproval() async throws {
    let lease = SSHRouteLease()
    let entered = AgentTestRequests()
    let record = HostKeyRecord(host: "example.test", port: 22, algorithm: "ssh-ed25519", fingerprintSHA256: "SHA256:test", publicKeyBase64: "test")
    let task = Task {
        await lease.requestPrompt(.unknown(record)) { _ in
            entered.append(Data([1]))
            // Simulate a UI decision already queued when cancellation arrives.
            try? await Task.sleep(for: .seconds(30))
            return .trustAndSave
        }
    }
    do { try await entered.waitForCount(1) }
    catch { await lease.close(); _ = await task.value; throw error }
    await lease.close()
    #expect(await task.value == .cancel)
}
