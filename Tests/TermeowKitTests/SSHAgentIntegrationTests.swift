import Crypto
import Darwin
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Testing
@testable import TermeowKit

/// Opt-in, entirely local fixtures. Never read or modify the user's real SSH agent or authorized_keys.
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["TERMEOW_AGENT_INTEGRATION_TESTS"] == "1"))
struct SSHAgentIntegrationTests {
    @Test func realOpenSSHAgentSignsEverySupportedAlgorithm() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let identities = try await SSHAgentClient.identities(socketPath: fixture.socketPath)
        #expect(identities.count == 5)
        #expect(Set(identities.map(\.algorithm)) == SSHAgentKeyMaterial.supportedAlgorithms)
        let message = Data("Termeow isolated agent signature test".utf8)
        for identity in identities {
            let algorithms = identity.algorithm == "ssh-rsa" ? ["rsa-sha2-512", "rsa-sha2-256"] : [identity.algorithm]
            for algorithm in algorithms {
                let signer = AgentSigner(identity: identity, path: fixture.socketPath, access: SSHAgentAccess(), timeout: 5)
                let signature = try await Task.detached { try signer.sign(message, algorithm: algorithm) }.value
                let material = try SSHAgentKeyMaterial(identity: identity)
                #expect(material.verify(signature, algorithm: algorithm, message: message))
                #expect(!material.verify(signature, algorithm: algorithm, message: message + Data([0])))
                let key = try SSHAgentAuthentication.key(
                    configuration: SSHAgentConfiguration(socketPath: fixture.socketPath, publicKey: identity.blob, rsaSHA256: algorithm == "rsa-sha2-256"),
                    access: SSHAgentAccess(), timeout: 5
                )
                var encoded = ByteBuffer()
                let count = key.publicKey.write(to: &encoded)
                #expect(count == identity.blob.count)
                #expect(Data(encoded.readableBytesView) == identity.blob)
            }
        }
    }

    @Test func realServerAcceptsAllAgentKeysAndBothRSADigests() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let port = try await fixture.startServer()
        for identity in try await SSHAgentClient.identities(socketPath: fixture.socketPath) {
            for sha256 in identity.algorithm == "ssh-rsa" ? [false, true] : [false] {
                var profile = fixture.profile(identity: identity, port: port)
                profile.agent.rsaSHA256 = sha256
                let connection = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
                do {
                    let result = try await connection.client.executeCommand("printf TERMEOW_AGENT_READY", maxResponseSize: 1024)
                    #expect(String(buffer: result) == "TERMEOW_AGENT_READY")
                    await connection.close()
                } catch { await connection.close(); throw error }
            }
        }
    }

    @Test func terminalSFTPAndMixedPrivateKeyJumpUseTheirOwnAgentIdentity() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let port = try await fixture.startServer()
        let identities = try await SSHAgentClient.identities(socketPath: fixture.socketPath)
        let ed = try #require(identities.first { $0.algorithm == "ssh-ed25519" })
        let p256 = try #require(identities.first { $0.algorithm == "ecdsa-sha2-nistp256" })
        for mode in 0...2 {
            var target = fixture.profile(identity: p256, port: port)
            var jumps: [SSHConnectionHop] = []
            if mode > 0 {
                var jump = fixture.profile(identity: ed, port: port)
                jump.name = "Agent jump"
                if mode == 2 {
                    jump.authMethod = .privateKey
                    jump.privateKeyBookmark = try fixture.directory.appendingPathComponent("ed25519").bookmarkData(options: [.withSecurityScope])
                }
                target.jumpHostID = jump.id
                jumps = [SSHConnectionHop(profile: jump, secret: "")]
            }
            target.startupCommand = "printf 'TERMEOW_AGENT_PTY_READY\\n'"
            let session = CitadelSSHSession(profile: target, secret: "", hostKeyStore: isolatedRouteHostKeyStore(), jumpHosts: jumps) { _ in .connectOnce }
            do {
                try await session.connect()
                #expect(session.state == .connected)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        var text = ""
                        for await data in session.output {
                            text += String(decoding: data, as: UTF8.self)
                            if text.contains("TERMEOW_AGENT_PTY_READY") { return }
                        }
                        throw SSHError.connectionClosed
                    }
                    group.addTask { try await Task.sleep(for: .seconds(5)); throw SSHError.timeout }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                await session.disconnect()
                #expect(session.state == .disconnected)
            } catch { await session.disconnect(); throw error }
            let sftp = CitadelSFTPService(profile: target, secret: "", hostKeyStore: isolatedRouteHostKeyStore(), jumpHosts: jumps) { _ in .connectOnce }
            do {
                _ = try await sftp.connect()
                let listing = try await sftp.listDirectory(at: fixture.directory.path)
                #expect(listing.items.contains { $0.name == "ed25519.pub" })
                await sftp.disconnect()
            } catch { await sftp.disconnect(); throw error }
        }
    }

    @Test func deniedMissingAndStaleKeysFailWithoutTryingOtherKeys() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let port = try await fixture.startServer()
        let identity = try #require(try await SSHAgentClient.identities(socketPath: fixture.socketPath).first)
        try await withMockAgent(reply: { _ in agentFrame(Data([5])) }) { agent in
            var profile = fixture.profile(identity: identity, port: port)
            profile.agent.socketPath = agent.path
            await #expect(throws: SSHError.sshAgent(.refused)) {
                _ = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
            }
            #expect(agent.requests.values.count == 1)
        }
        var profile = fixture.profile(identity: identity, port: port)
        profile.agent.publicKey = try edIdentity(Curve25519.Signing.PrivateKey()).blob
        await #expect(throws: SSHError.sshAgent(.refused)) {
            _ = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
        }
        profile.agent.socketPath += ".missing"
        await #expect(throws: SSHError.sshAgent(.unavailable)) {
            _ = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
        }
    }

    @Test func rejectsHostKeyBeforeRequestingAnyAgentSignature() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let port = try await fixture.startServer()
        let identity = try #require(try await SSHAgentClient.identities(socketPath: fixture.socketPath).first)
        try await withMockAgent(reply: { _ in nil }) { agent in
            var profile = fixture.profile(identity: identity, port: port)
            profile.agent.socketPath = agent.path
            await #expect(throws: SSHError.hostKeyRejected) {
                _ = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .cancel }
            }
            #expect(agent.requests.values.isEmpty)
        }
    }

    @Test func cancelPendingApprovalDoesNotBlockAnotherConnection() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let port = try await fixture.startServer()
        let identity = try #require(try await SSHAgentClient.identities(socketPath: fixture.socketPath).first)
        let working = fixture.profile(identity: identity, port: port)
        try await withMockAgent(reply: { _ in nil }) { agent in
            var pending = working
            pending.agent.socketPath = agent.path
            let profile = pending
            let task = Task {
                try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
            }
            do {
                try await agent.requests.waitForCount(1)
                let start = ContinuousClock.now
                let connection = try await CitadelConnectionFactory.connect(profile: working, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
                await connection.close()
                #expect(start.duration(to: .now) < .seconds(3))
            } catch { task.cancel(); _ = try? await task.value; throw error }
            let start = ContinuousClock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(start.duration(to: .now) < .seconds(2))

            var short = profile; short.timeoutSeconds = 1
            let deadlineStart = ContinuousClock.now
            do {
                _ = try await CitadelConnectionFactory.connect(profile: short, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
                Issue.record("An unresponsive agent must time out")
            } catch {
                #expect(error as? SSHError == .timeout || error as? SSHError == .sshAgent(.timedOut))
            }
            #expect(deadlineStart.duration(to: .now) < .seconds(3))
        }
    }

    @Test func approvalLongerThanCitadelDefaultTimeoutCanStillSucceed() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let port = try await fixture.startServer()
        let identity = try #require(try await SSHAgentClient.identities(socketPath: fixture.socketPath).first)
        // Delay only this isolated mock agent's thread to emulate a human approval dialog.
        try await withMockAgent(reply: { payload in
            Thread.sleep(forTimeInterval: 11)
            return try? agentFrame(SSHAgentAccess().request(path: fixture.socketPath, payload: payload, timeout: 2))
        }) { agent in
            var profile = fixture.profile(identity: identity, port: port)
            profile.timeoutSeconds = 15; profile.agent.socketPath = agent.path
            let connection = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
            #expect(connection.client.isConnected)
            await connection.close()
            #expect(agent.requests.values.count == 1)
        }
    }

    @Test func closedRouteReleasesItsAgentExecutorLifetime() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let port = try await fixture.startServer()
        let identity = try #require(try await SSHAgentClient.identities(socketPath: fixture.socketPath).first)
        let weak = WeakAgentRoute()
        let profile = fixture.profile(identity: identity, port: port)
        func exercise() async throws {
            let connection = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
            weak.lease = connection.lease
            await connection.close()
        }
        try await exercise()
        for _ in 0..<100 {
            if weak.lease == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(weak.lease == nil)
    }
}

private final class WeakAgentRoute { weak var lease: SSHRouteLease? }

private final class OpenSSHAgentFixture: @unchecked Sendable {
    let directory: URL
    let socketPath: String
    private let agent = Process()
    private var server: Process?

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/termeow-openssh-\(UUID().uuidString)")
        socketPath = directory.appendingPathComponent("agent.sock").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
            agent.arguments = ["-D", "-a", socketPath]
            agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
            try agent.run()
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath: socketPath) { break }
                usleep(10_000)
            }
            guard agent.isRunning, FileManager.default.fileExists(atPath: socketPath) else { throw SSHAgentError.unavailable }
            let variants = [("ed25519", "ed25519", "256"), ("rsa", "rsa", "2048"), ("p256", "ecdsa", "256"), ("p384", "ecdsa", "384"), ("p521", "ecdsa", "521")]
            for (name, type, bits) in variants {
                let path = directory.appendingPathComponent(name).path
                try run("/usr/bin/ssh-keygen", ["-q", "-t", type, "-b", bits, "-N", "", "-C", "Isolated Termeow test", "-f", path])
                try run("/usr/bin/ssh-add", [path], environment: ["SSH_AUTH_SOCK": socketPath, "SSH_ASKPASS_REQUIRE": "never"])
            }
        } catch { stop(); throw error }
    }

    func profile(identity: SSHAgentIdentity, port: Int) -> SessionProfile {
        SessionProfile(name: "Isolated agent test", host: "127.0.0.1", port: port, username: NSUserName(), authMethod: .agent,
                       keepAliveSeconds: 0, timeoutSeconds: 5, agent: SSHAgentConfiguration(socketPath: socketPath, publicKey: identity.blob))
    }

    func startServer() async throws -> Int {
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(probe.localAddress?.port)
        try await probe.close()
        let hostKey = directory.appendingPathComponent("host").path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        let authorized = try ["ed25519", "rsa", "p256", "p384", "p521"].map {
            try String(contentsOf: directory.appendingPathComponent("\($0).pub"), encoding: .utf8)
        }.joined(separator: "\n")
        let keysURL = directory.appendingPathComponent("authorized_keys")
        try authorized.write(to: keysURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
        let config = """
        ListenAddress 127.0.0.1
        Port \(port)
        HostKey \(hostKey)
        PidFile \(directory.path)/sshd.pid
        AuthorizedKeysFile \(keysURL.path)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AllowTcpForwarding yes
        MaxAuthTries 1
        LogLevel ERROR
        Subsystem sftp internal-sftp
        """
        let configURL = directory.appendingPathComponent("sshd_config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", configURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run(); server = process
        for _ in 0..<100 {
            guard process.isRunning else { throw SSHError.connectionFailed }
            if let channel = try? await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(.milliseconds(100)).connect(host: "127.0.0.1", port: port).get() {
                try? await channel.close(); return port
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SSHError.timeout
    }

    func stop() {
        for process in [server, agent].compactMap({ $0 }) where process.isRunning {
            process.terminate()
            for _ in 0..<100 { if !process.isRunning { break }; usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value } }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SSHError.connectionFailed }
    }
}
