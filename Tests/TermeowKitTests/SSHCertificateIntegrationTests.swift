@preconcurrency import Citadel
import Foundation
import NIOCore
import Testing
@testable import TermeowKit

@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if:
    ProcessInfo.processInfo.environment["TERMEOW_CERTIFICATE_INTEGRATION_TESTS"] == "1" ||
    ProcessInfo.processInfo.environment["TERMEOW_AGENT_INTEGRATION_TESTS"] == "1"
))
struct SSHCertificateIntegrationTests {
    @Test func openSSHAcceptsEveryAgentCertificateAndBothRSADigests() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub")
        let identities = try await SSHAgentClient.identities(socketPath: fixture.socketPath)
        for name in ["ed25519", "rsa", "p256", "p384", "p521"] {
            let certificate = try fixture.signCertificate(key: name, ca: ca)
            let parsed = try certificate.load()
            let identity = try #require(identities.first { $0.blob == parsed.publicKey.blob })
            for sha256 in name == "rsa" ? [false, true] : [false] {
                var profile = fixture.profile(identity: identity, port: port)
                profile.agent.rsaSHA256 = sha256; profile.certificate = certificate
                try await verifyCertificateCommand(profile)
            }
        }
    }

    @Test func validatesAllSupportedAuthorityAlgorithms() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        for (type, bits) in [("ed25519", 256), ("rsa", 2048), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521)] {
            let ca = try fixture.certificateAuthority(type: type, bits: bits)
            let configuration = try fixture.signCertificate(key: "ed25519", ca: ca)
            let certificate = try configuration.load()
            try certificate.validate()
            #expect(certificate.authority.isSupported)
            #expect(certificate.publicKey.algorithm == "ssh-ed25519")
        }
    }

    @Test func privateKeyCertificatesSupportOpenSSHPEMAndPassphrases() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub")
        for name in ["ed25519", "rsa"] {
            let certificate = try fixture.signCertificate(key: name, ca: ca)
            for encrypted in [false, true] {
                let file = fixture.directory.appendingPathComponent("\(name)-\(encrypted ? "encrypted" : "plain")")
                try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent(name), to: file)
                let secret = encrypted ? "isolated-test-passphrase" : ""
                if encrypted { try fixture.run("/usr/bin/ssh-keygen", ["-p", "-P", "", "-N", secret, "-f", file.path]) }
                let profile = try fixture.privateCertificateProfile(file: file, certificate: certificate, port: port)
                try await verifyCertificateCommand(profile, secret: secret)
            }
            if name == "rsa" {
                let file = fixture.directory.appendingPathComponent("rsa-pem")
                try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent(name), to: file)
                try fixture.run("/usr/bin/ssh-keygen", ["-p", "-m", "PEM", "-P", "", "-N", "", "-f", file.path])
                try await verifyCertificateCommand(fixture.privateCertificateProfile(file: file, certificate: certificate, port: port))
                let pkcs8 = fixture.directory.appendingPathComponent("rsa-pkcs8")
                try fixture.run("/usr/bin/openssl", ["pkcs8", "-topk8", "-nocrypt", "-in", file.path, "-out", pkcs8.path])
                try await verifyCertificateCommand(fixture.privateCertificateProfile(file: pkcs8, certificate: certificate, port: port))
            }
        }
    }

    @Test func certificatesWorkAcrossMixedJumpsTerminalAndSFTP() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub")
        let outerCertificate = try fixture.signCertificate(key: "rsa", ca: ca)
        let outer = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("rsa"), certificate: outerCertificate, port: port)
        let targetCertificate = try fixture.signCertificate(key: "p256", ca: ca)
        let targetKey = try targetCertificate.load().publicKey.blob
        let identity = try #require(try await SSHAgentClient.identities(socketPath: fixture.socketPath).first { $0.blob == targetKey })
        var target = fixture.profile(identity: identity, port: port)
        target.certificate = targetCertificate; target.jumpHostID = outer.id
        target.startupCommand = "printf 'TERMEOW_CERTIFICATE_PTY\\n'"
        let hops = [SSHConnectionHop(profile: outer, secret: "")]
        let session = CitadelSSHSession(profile: target, secret: "", hostKeyStore: isolatedRouteHostKeyStore(), jumpHosts: hops) { _ in .connectOnce }
        do {
            try await session.connect()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var output = ""
                    for await bytes in session.output {
                        output += String(decoding: bytes, as: UTF8.self)
                        if output.contains("TERMEOW_CERTIFICATE_PTY") { return }
                    }
                    throw SSHError.connectionClosed
                }
                group.addTask { try await Task.sleep(for: .seconds(5)); throw SSHError.timeout }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            await session.disconnect()
        } catch { await session.disconnect(); throw error }
        let sftp = CitadelSFTPService(profile: target, secret: "", hostKeyStore: isolatedRouteHostKeyStore(), jumpHosts: hops) { _ in .connectOnce }
        do {
            _ = try await sftp.connect()
            #expect(try await sftp.listDirectory(at: fixture.directory.path).items.contains { $0.name == "p256-cert.pub" })
            await sftp.disconnect()
        } catch { await sftp.disconnect(); throw error }
    }

    @Test func serverPrincipalMappingIsNotRestrictedToTheLoginUsername() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let principals = fixture.directory.appendingPathComponent("principals")
        try "deployment-role\n".write(to: principals, atomically: true, encoding: .utf8)
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub", extraOptions: ["AuthorizedPrincipalsFile \(principals.path)"])
        let certificate = try fixture.signCertificate(key: "ed25519", ca: ca, principals: "deployment-role")
        let profile = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("ed25519"), certificate: certificate, port: port)
        #expect(profile.username != "deployment-role")
        try await verifyCertificateCommand(profile)
    }

    @Test func rejectedCertificateNeverFallsBackToAnAuthorizedPlainKey() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let trusted = try fixture.certificateAuthority()
        let untrusted = try fixture.certificateAuthority(type: "ecdsa", bits: 256)
        // The plain key is authorized: success here would reveal an unsafe fallback.
        let port = try await fixture.startServer(authorizedKeys: ["ed25519"], maxAuthTries: 2, trustedCA: trusted + ".pub")
        let certificate = try fixture.signCertificate(key: "ed25519", ca: untrusted)
        let profile = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("ed25519"), certificate: certificate, port: port)
        await #expect(throws: SSHError.authenticationFailed) { try await verifyCertificateCommand(profile) }
        var plain = profile; plain.certificate.enabled = false
        try await verifyCertificateCommand(plain)
    }

    @Test func rejectsExpiredAndMismatchedAgentCertificatesBeforeNetworkOrApproval() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let identities = try await SSHAgentClient.identities(socketPath: fixture.socketPath)
        let certificate = try fixture.signCertificate(key: "ed25519", ca: ca)
        let wrong = try #require(identities.first { $0.algorithm == "ssh-rsa" })
        var profile = fixture.profile(identity: wrong, port: 1)
        profile.certificate = certificate
        await #expect(throws: SSHError.sshCertificate(.keyMismatch)) {
            _ = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in
                Issue.record("Mismatched agent certificates must fail before host verification"); return .cancel
            }
        }
        profile.certificate = try fixture.signCertificate(key: "ed25519", ca: ca, validity: "-2h:-1h")
        await #expect(throws: SSHError.sshCertificate(.expired)) {
            _ = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in
                Issue.record("Expired certificates must fail before host verification"); return .cancel
            }
        }
    }

    @Test func serverEnforcesNoPTYWhileAllowingSFTP() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub")
        let certificate = try fixture.signCertificate(key: "ed25519", ca: ca, options: ["no-pty"])
        let profile = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("ed25519"), certificate: certificate, port: port)
        let terminal = CitadelSSHSession(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
        await #expect(throws: SSHError.connectionFailed) { try await terminal.connect() }
        #expect(terminal.state != .connected)
        await terminal.disconnect()
        let sftp = CitadelSFTPService(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
        do { _ = try await sftp.connect(); await sftp.disconnect() }
        catch { await sftp.disconnect(); throw error }
    }

    @Test func privateKeyMismatchFailsAndRenewalIsReadOnReconnect() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub")
        let certificate = try fixture.signCertificate(key: "ed25519", ca: ca)
        let wrong = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("rsa"), certificate: certificate, port: port)
        await #expect(throws: SSHError.sshCertificate(.keyMismatch)) { try await verifyCertificateCommand(wrong) }
        let profile = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("ed25519"), certificate: certificate, port: port)
        try await verifyCertificateCommand(profile)
        // Replace the file behind the original bookmark; never update the saved profile.
        _ = try fixture.signCertificate(key: "ed25519", ca: ca, validity: "-2h:-1h")
        await #expect(throws: SSHError.sshCertificate(.expired)) { try await verifyCertificateCommand(profile) }
        _ = try fixture.signCertificate(key: "ed25519", ca: ca)
        try await verifyCertificateCommand(profile)
    }

    @Test func serverRejectsWrongPrincipalsAndUnknownCriticalOptions() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: ["ed25519"], maxAuthTries: 2, trustedCA: ca + ".pub")
        for (principals, options) in [("no-such-certificate-role", [String]()), (NSUserName(), ["critical:unknown@example.test=value"])] {
            let certificate = try fixture.signCertificate(key: "ed25519", ca: ca, principals: principals, options: options)
            let profile = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("ed25519"), certificate: certificate, port: port)
            await #expect(throws: SSHError.authenticationFailed) { try await verifyCertificateCommand(profile) }
        }
    }

    @Test func certificateForceCommandIsEnforcedByTheServer() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub")
        let certificate = try fixture.signCertificate(key: "ed25519", ca: ca, options: ["force-command=printf SERVER_FORCED_COMMAND"])
        let profile = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("ed25519"), certificate: certificate, port: port)
        let connection = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
        do {
            let output = try await connection.client.executeCommand("printf CLIENT_COMMAND_SHOULD_NOT_RUN", maxResponseSize: 1024)
            #expect(String(buffer: output) == "SERVER_FORCED_COMMAND")
            await connection.close()
        } catch { await connection.close(); throw error }
    }

    @Test(arguments: [false, true]) func certificatePermissionsControlAllForwardingModes(restricted: Bool) async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub")
        let certificate = try fixture.signCertificate(key: "ed25519", ca: ca, options: restricted ? ["no-port-forwarding"] : [])
        let profile = try fixture.privateCertificateProfile(file: fixture.directory.appendingPathComponent("ed25519"), certificate: certificate, port: port)
        let echo = try await echoServer()
        defer { echo.close(promise: nil) }
        let destination = try #require(echo.localAddress?.port)
        var ports: Set<Int> = []
        while ports.count < 3 { ports.insert(try await unusedPort()) }
        let sorted = ports.sorted()
        let remote = PortForwardRule(kind: .remote, bindPort: sorted[0], destinationPort: destination)
        let local = PortForwardRule(bindPort: sorted[1], destinationPort: destination)
        let dynamic = PortForwardRule(kind: .dynamic, bindPort: sorted[2])
        let connection = try await CitadelConnectionFactory.connect(profile: profile, secret: "", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
        let manager = SSHPortForwarding(connection: connection, rules: [remote, local, dynamic]) { _ in }
        do {
            await manager.startEnabled()
            let proxy: [UInt8] = [5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, UInt8(destination >> 8), UInt8(destination & 255)]
            if restricted {
                // Starting a remote rule is asynchronous; wait for the server's rejection.
                for _ in 0..<250 {
                    if await manager.snapshot.first(where: { $0.id == remote.id })?.state != .starting { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let status = try #require(await manager.snapshot.first { $0.id == remote.id })
                if case .failed = status.state {} else { Issue.record("The server must deny remote forwarding") }
                let reply = try await exchange(port: dynamic.bindPort, bytes: proxy)
                #expect(Array(reply.prefix(4)) == [5, 0, 5, 1])
                let localReply = try? await exchange(port: local.bindPort, bytes: [42])
                #expect(localReply != [42])
            } else {
                try await waitUntilListening(manager)
                #expect(try await exchange(port: remote.bindPort, bytes: [1, 2, 3]) == [1, 2, 3])
                #expect(try await exchange(port: local.bindPort, bytes: [4, 5, 6]) == [4, 5, 6])
                let reply = try await exchange(port: dynamic.bindPort, bytes: proxy + [42])
                #expect(Array(reply.prefix(4)) == [5, 0, 5, 0])
                #expect(Array(reply.dropFirst(12)) == [42])
            }
            #expect(connection.client.isConnected)
            await manager.shutdown(); await connection.close()
        } catch { await manager.shutdown(); await connection.close(); throw error }
    }

    @Test func certificateAgentApprovalStillHonorsCancellation() async throws {
        let fixture = try await Task.detached { try OpenSSHAgentFixture() }.value
        defer { fixture.stop() }
        let ca = try fixture.certificateAuthority()
        let port = try await fixture.startServer(authorizedKeys: [], trustedCA: ca + ".pub")
        let certificate = try fixture.signCertificate(key: "ed25519", ca: ca)
        let identity = try certificate.load().publicKey
        try await withMockAgent(reply: { _ in nil }) { agent in
            var pending = fixture.profile(identity: identity, port: port)
            pending.agent.socketPath = agent.path; pending.certificate = certificate
            let profile = pending
            let task = Task { try await verifyCertificateCommand(profile) }
            do { try await agent.requests.waitForCount(1) }
            catch { task.cancel(); _ = try? await task.value; throw error }
            let start = ContinuousClock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(start.duration(to: .now) < .seconds(2))
            #expect(agent.requests.values.count == 1)
        }
    }
}

private func verifyCertificateCommand(_ profile: SessionProfile, secret: String = "") async throws {
    let connection = try await CitadelConnectionFactory.connect(profile: profile, secret: secret, hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
    do {
        let output = try await connection.client.executeCommand("printf TERMEOW_CERTIFICATE_READY", maxResponseSize: 1024)
        #expect(String(buffer: output) == "TERMEOW_CERTIFICATE_READY")
        await connection.close()
    } catch { await connection.close(); throw error }
}

extension OpenSSHAgentFixture {
    func certificateAuthority(type: String = "ed25519", bits: Int = 256) throws -> String {
        let path = directory.appendingPathComponent("ca-\(type)-\(bits)").path
        if !FileManager.default.fileExists(atPath: path) {
            try run("/usr/bin/ssh-keygen", ["-q", "-t", type, "-b", String(bits), "-N", "", "-f", path])
        }
        return path
    }

    func signCertificate(key: String, ca: String, principals: String = NSUserName(), validity: String = "-1m:+1h", options: [String] = []) throws -> SSHCertificateConfiguration {
        var arguments = ["-q", "-s", ca, "-I", "Isolated certificate test", "-n", principals, "-V", validity, "-z", "42"]
        for option in options { arguments += ["-O", option] }
        arguments.append(directory.appendingPathComponent("\(key).pub").path)
        try run("/usr/bin/ssh-keygen", arguments)
        let file = directory.appendingPathComponent("\(key)-cert.pub")
        return SSHCertificateConfiguration(enabled: true, bookmark: try file.bookmarkData(options: .withSecurityScope), fileName: file.lastPathComponent)
    }

    func privateCertificateProfile(file: URL, certificate: SSHCertificateConfiguration, port: Int) throws -> SessionProfile {
        SessionProfile(name: "Isolated certificate test", host: "127.0.0.1", port: port, username: NSUserName(), authMethod: .privateKey,
                       privateKeyBookmark: try file.bookmarkData(options: .withSecurityScope), keepAliveSeconds: 0, timeoutSeconds: 5, certificate: certificate)
    }
}
