import Crypto
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Testing
@testable import TermeowKit

@Suite(.timeLimit(.minutes(1)))
struct SSHAgentTests {
    @Test func configurationRoundTripsWithoutSecretsAndDefaultsLegacySessions() throws {
        let identity = try edIdentity(Curve25519.Signing.PrivateKey())
        let configuration = SSHAgentConfiguration(socketPath: "/tmp/test-agent.sock", publicKey: identity.blob, rsaSHA256: true)
        let profile = SessionProfile(name: "agent", host: "example.test", username: "test", authMethod: .agent, agent: configuration)
        let encoded = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(SessionProfile.self, from: encoded) == profile)
        #expect(profile.isValidForSaving)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "agent"); legacy["authMethod"] = "password"
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.agent == SSHAgentConfiguration())
        #expect(decoded.isValidForSaving)
        var invalid = profile
        invalid.agent.publicKey = nil
        #expect(!invalid.isValidForSaving)
        #expect(configuration.identity?.id == identity.id)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE KEY"))
    }

    @Test func socketResolutionIsExplicitAndRejectsInvalidPaths() throws {
        #expect(try SSHAgentConfiguration().resolvedSocketPath(environment: ["SSH_AUTH_SOCK": "/tmp/environment.sock"]) == "/tmp/environment.sock")
        #expect(try SSHAgentConfiguration(socketPath: "/tmp/explicit.sock").resolvedSocketPath(environment: ["SSH_AUTH_SOCK": "/tmp/ignored.sock"]) == "/tmp/explicit.sock")
        #expect(throws: SSHAgentError.unavailable) { try SSHAgentConfiguration().resolvedSocketPath(environment: [:]) }
        for path in ["relative.sock", "/tmp/a\u{0}b", "/tmp/a\nb", "/" + String(repeating: "a", count: 104)] {
            #expect(throws: SSHAgentError.invalidSocket) { try SSHAgentConfiguration(socketPath: path).resolvedSocketPath() }
        }
    }

    @Test func parsesDeduplicatesAndSanitizesPublicIdentities() throws {
        let identity = try edIdentity(Curve25519.Signing.PrivateKey())
        var unsupported = AgentWire(); unsupported.append("sk-ssh-ed25519@openssh.com"); unsupported.append(Data(repeating: 1, count: 32))
        var response = AgentWire(Data([12])); response.append(UInt32(3))
        response.append(identity.blob); response.append("Test\nkey\u{1b}")
        response.append(identity.blob); response.append("duplicate")
        response.append(unsupported.data); response.append("Security key")
        let keys = try SSHAgentClient.decodeIdentities(response.data)
        #expect(keys.count == 2)
        #expect(keys[0].comment == "Testkey")
        #expect(keys[0].isSupported)
        #expect(!keys[1].isSupported)
        #expect(SSHAgentConfiguration(publicKey: keys[1].blob).validationError != nil)
        #expect(keys[0].authorizedKey.hasPrefix("ssh-ed25519 "))
    }

    @Test func weakRSAIsDisabledWithoutHidingOtherAgentKeys() throws {
        let ed = try edIdentity(Curve25519.Signing.PrivateKey())
        var weak = AgentWire(); weak.append("ssh-rsa"); weak.append(Data([1, 0, 1]))
        weak.append(Data([0, 0x80]) + Data(repeating: 0, count: 126) + Data([1]))
        var response = AgentWire(Data([12])); response.append(UInt32(2))
        response.append(weak.data); response.append("Legacy key")
        response.append(ed.blob); response.append("Supported key")
        let keys = try SSHAgentClient.decodeIdentities(response.data)
        #expect(keys.count == 2)
        #expect(!keys[0].isSupported)
        #expect(keys[1].isSupported)
    }

    @Test func rejectsMalformedIdentityMessages() throws {
        let identity = try edIdentity(Curve25519.Signing.PrivateKey())
        var response = AgentWire(Data([12])); response.append(UInt32(1)); response.append(identity.blob); response.append("Test")
        for length in 0..<response.data.count {
            #expect(throws: SSHAgentError.self) { try SSHAgentClient.decodeIdentities(Data(response.data.prefix(length))) }
        }
        #expect(throws: SSHAgentError.invalidResponse) { try SSHAgentClient.decodeIdentities(response.data + Data([0])) }
        #expect(throws: SSHAgentError.refused) { try SSHAgentClient.decodeIdentities(Data([5])) }
        #expect(throws: SSHAgentError.invalidResponse) { try SSHAgentClient.decodeIdentities(Data([12, 0xff, 0xff, 0xff, 0xff])) }
        var malformed = AgentWire(); malformed.append("ssh-ed25519"); malformed.append(Data(repeating: 0, count: 31))
        #expect(throws: SSHAgentError.invalidResponse) { try SSHAgentIdentity(blob: malformed.data, comment: "bad") }
        #expect(throws: SSHAgentError.invalidResponse) { try SSHAgentIdentity(blob: identity.blob + Data([0]), comment: "bad") }
    }

    @Test func fragmentedRepliesAreReassembled() async throws {
        let identity = try edIdentity(Curve25519.Signing.PrivateKey())
        var response = AgentWire(Data([12])); response.append(UInt32(1)); response.append(identity.blob); response.append("Fixture")
        let packet = agentFrame(response.data)
        try await withMockAgent(fragmentSize: 1, reply: { _ in packet }) { agent in
            let keys = try await SSHAgentClient.identities(socketPath: agent.path)
            #expect(keys.map(\.blob) == [identity.blob])
            #expect(agent.requests.values == [Data([11])])
        }
    }

    @Test func oversizedAndEmptyFramesAreRejectedBeforeReadingTheirBodies() async throws {
        for header: Data in [Data([0, 0, 0, 0]), Data([0, 0x10, 0, 1]), Data([0xff, 0xff, 0xff, 0xff])] {
            _ = try await withMockAgent(reply: { _ in header }) { agent in
                await #expect(throws: SSHAgentError.invalidResponse) { try await SSHAgentClient.identities(socketPath: agent.path) }
            }
        }
    }

    @Test func verifiesEd25519SignaturesAndPinsTheRequestedKey() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = try edIdentity(privateKey)
        let message = Data("ssh authentication payload".utf8)
        try await withMockAgent(reply: { data in
            var request = AgentWire(data)
            guard (try? request.byte()) == 13, (try? request.bytes()) == identity.blob,
                  let message = try? request.bytes(), (try? request.uint32()) == 0, request.isEmpty,
                  let raw = try? privateKey.signature(for: message) else { return agentFrame(Data([5])) }
            return agentSignatureFrame(algorithm: "ssh-ed25519", signature: raw)
        }) { agent in
            let signer = AgentSigner(identity: identity, path: agent.path, access: SSHAgentAccess(), timeout: 2)
            let raw = try await Task.detached { try signer.sign(message, algorithm: "ssh-ed25519") }.value
            #expect(privateKey.publicKey.isValidSignature(raw, for: message))
            #expect(agent.requests.values.count == 1)
        }
    }

    @Test func refusesWrongAlgorithmsInvalidSignaturesAndAgentFailures() async throws {
        let identity = try edIdentity(Curve25519.Signing.PrivateKey())
        let fixtures: [(Data, SSHAgentError)] = [
            (agentFrame(Data([5])), .refused),
            (agentSignatureFrame(algorithm: "ssh-rsa", signature: Data(repeating: 0, count: 64)), .invalidSignature),
            (agentSignatureFrame(algorithm: "ssh-ed25519", signature: Data(repeating: 0, count: 64)), .invalidSignature),
            (agentFrame(Data([14, 0xff, 0xff, 0xff, 0xff])), .invalidResponse),
        ]
        for (packet, expected) in fixtures {
            try await withMockAgent(reply: { _ in packet }) { agent in
                let access = SSHAgentAccess()
                let signer = AgentSigner(identity: identity, path: agent.path, access: access, timeout: 2)
                await #expect(throws: expected) {
                    try await Task.detached { try signer.sign(Data([1]), algorithm: "ssh-ed25519") }.value
                }
                #expect(access.lastError == expected)
            }
        }
    }

    @Test func cancellationAndDeadlineInterruptUnresponsiveAgents() async throws {
        try await withMockAgent(reply: { _ in nil }) { agent in
            let task = Task { try await SSHAgentClient.identities(socketPath: agent.path) }
            try await agent.requests.waitForCount(1)
            let start = ContinuousClock.now
            task.cancel()
            await #expect(throws: SSHAgentError.cancelled) { try await task.value }
            #expect(start.duration(to: .now) < .seconds(1))

            let access = SSHAgentAccess()
            await #expect(throws: SSHAgentError.timedOut) {
                try await Task.detached { try access.request(path: agent.path, payload: Data([11]), timeout: 0.15) }.value
            }
            access.cancel()
            #expect(throws: SSHAgentError.cancelled) { try access.request(path: agent.path, payload: Data([11]), timeout: 1) }
        }
    }

    @Test func unavailableSocketDoesNotHang() async throws {
        await #expect(throws: SSHAgentError.unavailable) {
            try await SSHAgentClient.identities(socketPath: "/tmp/termeow-missing-\(UUID().uuidString).sock")
        }
    }
}

func edIdentity(_ key: Curve25519.Signing.PrivateKey) throws -> SSHAgentIdentity {
    var wire = AgentWire(); wire.append("ssh-ed25519"); wire.append(key.publicKey.rawRepresentation)
    return try SSHAgentIdentity(blob: wire.data, comment: "Ephemeral test identity")
}

func agentFrame(_ body: Data) -> Data { var wire = AgentWire(); wire.append(body); return wire.data }
func agentSignatureFrame(algorithm: String, signature: Data) -> Data {
    var wire = AgentWire(); wire.append(algorithm); wire.append(signature)
    var response = AgentWire(Data([14])); response.append(wire.data)
    return agentFrame(response.data)
}

final class AgentTestRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    var values: [Data] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    func waitForCount(_ count: Int) async throws {
        for _ in 0..<300 {
            if values.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SSHError.timeout
    }
}

struct MockSSHAgent: Sendable {
    let path: String
    let requests: AgentTestRequests
}

func withMockAgent<T>(fragmentSize: Int = 0, reply: @escaping @Sendable (Data) -> Data?, body: (MockSSHAgent) async throws -> T) async throws -> T {
    let directory = URL(fileURLWithPath: "/tmp/termeow-agent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let children = AgentTestChannels()
    let requests = AgentTestRequests()
    let path = directory.appendingPathComponent("agent.sock").path
    do {
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            children.add(channel)
            return channel.pipeline.addHandler(MockAgentHandler(fragmentSize: fragmentSize, requests: requests, reply: reply))
        }.bind(unixDomainSocketPath: path).get()
        do {
            let result = try await body(MockSSHAgent(path: path, requests: requests))
            try await server.close(); await children.close(); try await group.shutdownGracefully()
            return result
        } catch {
            try? await server.close(); throw error
        }
    } catch {
        await children.close(); try? await group.shutdownGracefully(); throw error
    }
}

private final class AgentTestChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [Channel] = []
    func add(_ channel: Channel) { lock.lock(); channels.append(channel); lock.unlock() }
    private func snapshot() -> [Channel] { lock.lock(); defer { lock.unlock() }; return channels }
    func close() async { for channel in snapshot() { try? await channel.close() } }
}

private final class MockAgentHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let fragmentSize: Int
    let requests: AgentTestRequests
    let reply: @Sendable (Data) -> Data?
    var buffer = ByteBuffer()
    init(fragmentSize: Int, requests: AgentTestRequests, reply: @escaping @Sendable (Data) -> Data?) {
        self.fragmentSize = fragmentSize; self.requests = requests; self.reply = reply
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data); buffer.writeBuffer(&input)
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self), length <= 1_048_576,
              buffer.readableBytes >= 4 + Int(length) else { return }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let bytes = buffer.readBytes(length: Int(length)) else { return }
        let request = Data(bytes); requests.append(request)
        guard let response = reply(request) else { return }
        let size = fragmentSize > 0 ? fragmentSize : max(1, response.count)
        for start in stride(from: 0, to: response.count, by: size) {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: response[start..<min(start + size, response.count)])), promise: nil)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
