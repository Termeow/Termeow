@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

enum CitadelConnectionFactory {
    static func connect(
        profile: SessionProfile,
        secret: String,
        hostKeyStore: HostKeyStore,
        jumpHosts: [SSHConnectionHop] = [],
        prompt: @escaping HostKeyPromptHandler
    ) async throws -> CitadelConnection {
        let route = jumpHosts + [SSHConnectionHop(profile: profile, secret: secret)]
        // Agent consent must not block any unrelated SSH connection's event loop.
        let agentAccess = SSHAgentAccess()
        let agentGroup = route.contains { $0.profile.authMethod == .agent } ? MultiThreadedEventLoopGroup(numberOfThreads: 1) : nil
        let lease = SSHRouteLease(agentAccess: agentAccess, agentGroup: agentGroup)
        return try await withTaskCancellationHandler {
            do {
                try SSHConnectionRoute.validatePreparedRoute(jumpHosts: jumpHosts, destination: profile)
                // Resolve all credentials before opening sockets, including key bookmarks.
                let settings = try route.enumerated().map { index, hop in
                    do {
                        return try connectionSettings(profile: hop.profile, secret: hop.secret, hostKeyStore: hostKeyStore, agentAccess: agentAccess, agentGroup: agentGroup) { check in
                            await lease.requestPrompt(check, using: prompt)
                        }
                    } catch {
                        if index < jumpHosts.count {
                            throw SSHError.jumpHostFailed(hop.profile.displayName, mapError(error))
                        }
                        throw error
                    }
                }
                var previous: SSHClientBox?
                for (index, setting) in settings.enumerated() {
                    try Task.checkCancellation()
                    do {
                        let client = try await connectHop(setting, previous: previous, lease: lease)
                        try await lease.add(client)
                        previous = client
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        let failure = await lease.didTimeOut ? SSHError.timeout : agentAccess.lastError.map(SSHError.sshAgent) ?? mapError(error)
                        if index < jumpHosts.count {
                            throw SSHError.jumpHostFailed(route[index].profile.displayName, failure)
                        }
                        throw failure
                    }
                }
                try Task.checkCancellation()
                guard let previous else { throw SSHError.connectionFailed }
                return CitadelConnection(client: previous.value, lease: lease)
            } catch {
                await lease.close()
                if error is CancellationError { throw error }
                throw mapError(error)
            }
        } onCancel: {
            agentAccess.cancel()
            Task { await lease.close() }
        }
    }

    private static func connectHop(_ settings: SSHClientSettings, previous: SSHClientBox?, lease: SSHRouteLease) async throws -> SSHClientBox {
        try await withThrowingTaskGroup(of: SSHClientBox.self) { group in
            group.addTask {
                let client: SSHClient
                if let previous {
                    client = try await previous.value.jump(to: settings)
                } else {
                    let channel = try await ClientBootstrap(group: settings.group)
                        .channelOption(ChannelOptions.autoRead, value: false)
                        .channelInitializer { channel in
                            channel.pipeline.addHandler(SSHInitialReadGate())
                        }
                        .connectTimeout(settings.connectTimeout)
                        .connect(host: settings.host, port: settings.port).get()
                    try await lease.setTransport(channel)
                    // Citadel's existing-channel API installs synchronous pipeline handlers.
                    // Keep its async entry point on the channel's event loop, not the global executor.
                    client = try await withTaskExecutorPreference(SSHEventLoopExecutor(channel.eventLoop)) {
                        try await SSHClient.connect(on: channel, settings: settings)
                    }
                }
                if Task.isCancelled {
                    try? await client.close()
                    throw CancellationError()
                }
                return SSHClientBox(value: client)
            }
            group.addTask {
                try await Task.sleep(for: .nanoseconds(settings.connectTimeout.nanoseconds))
                await lease.expire()
                throw SSHError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SSHError.connectionFailed }
            return result
        }
    }

    private static func connectionSettings(profile: SessionProfile, secret: String, hostKeyStore: HostKeyStore, agentAccess: SSHAgentAccess, agentGroup: MultiThreadedEventLoopGroup?, prompt: @escaping HostKeyPromptHandler) throws -> SSHClientSettings {
        let auth = AuthBox(try authenticationMethod(profile: profile, secret: secret, agentAccess: agentAccess))
        let validator = PromptingHostKeyValidator(
            host: profile.host,
            port: profile.port,
            store: hostKeyStore,
            prompt: prompt
        )
        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { auth.method },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = .seconds(Int64(max(profile.timeoutSeconds, 1)))
        if let agentGroup { settings.group = agentGroup }
        return settings
    }

    static func mapError(_ error: Error) -> SSHError {
        if let ssh = error as? SSHError { return ssh }
        if let agent = error as? SSHAgentError { return .sshAgent(agent) }
        if let certificate = error as? SSHCertificateError { return .sshCertificate(certificate) }
        if error is SSHRouteError { return .invalidJumpRoute }
        if error is InvalidHostKey { return .unknownHostKey }
        let text = String(describing: error).lowercased()
        if text.contains("auth") { return .authenticationFailed }
        if text.contains("timeout") { return .timeout }
        if text.contains("closed") { return .connectionClosed }
        return .connectionFailed
    }

    private static func authenticationMethod(profile: SessionProfile, secret: String, agentAccess: SSHAgentAccess) throws -> SSHAuthenticationMethod {
        let certificate = profile.certificate.enabled ? try profile.certificate.load() : nil
        try certificate?.validate()
        let method: SSHAuthenticationMethod
        switch profile.authMethod {
        case .password:
            guard certificate == nil else { throw SSHCertificateError.invalidAuthentication }
            guard !secret.isEmpty else { throw SSHError.missingCredential }
            method = .passwordBased(username: profile.username, password: secret)
        case .privateKey:
            method = try privateKeyAuth(profile: profile, secret: secret)
        case .agent:
            if let certificate { try certificate.validate(matching: profile.agent.publicKey) }
            method = try SSHAgentAuthentication.method(username: profile.username, configuration: profile.agent, access: agentAccess, timeout: TimeInterval(max(profile.timeoutSeconds, 1)))
        }
        guard let certificate else { return method }
        return try SSHCertificateAuthentication.method(base: method, certificate: certificate, rsaSHA256: profile.authMethod == .agent && profile.agent.rsaSHA256)
    }

    private static func privateKeyAuth(profile: SessionProfile, secret: String) throws -> SSHAuthenticationMethod {
        do {
            guard let bookmark = profile.privateKeyBookmark else { throw SSHError.invalidPrivateKey }
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else { throw SSHError.invalidPrivateKey }
            defer { url.stopAccessingSecurityScopedResource() }
            let keyText = try String(contentsOf: url, encoding: .utf8)
            return try privateKeyAuthentication(username: profile.username, keyText: keyText, secret: secret, forCertificate: profile.certificate.enabled)
        } catch let error as SSHError {
            throw error
        } catch {
            throw SSHError.invalidPrivateKey
        }
    }

    static func privateKeyAuthentication(username: String, keyText: String, secret: String, forCertificate: Bool = false) throws -> SSHAuthenticationMethod {
        if let rsaKey = try PrivateKeyMaterial.rsaPEMKey(from: keyText) {
            return try RSASHA2Authentication.method(username: username, key: rsaKey)
        }
        let keyText = try PrivateKeyMaterial.normalizedOpenSSHKey(from: keyText)
        let passphrase = secret.isEmpty ? nil : Data(secret.utf8)
        do {
            let type = try SSHKeyDetection.detectPrivateKeyType(from: keyText)
            switch type {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: passphrase)
                return .ed25519(username: username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: passphrase)
                if forCertificate { return SSHCertificateAuthentication.rsaMethod(username: username, key: key) }
                return .rsa(username: username, privateKey: key)
            case .ecdsaP256, .ecdsaP384, .ecdsaP521:
                throw SSHError.unsupportedAlgorithm
            default:
                throw SSHError.unsupportedAlgorithm
            }
        } catch let error as SSHError {
            throw error
        } catch {
            throw SSHError.invalidPrivateKey
        }
    }
}

private final class SSHEventLoopExecutor: TaskExecutor {
    let eventLoop: any EventLoop
    init(_ eventLoop: any EventLoop) { self.eventLoop = eventLoop }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        eventLoop.execute { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// Do not lose an eager server banner between TCP connect and installation of the SSH pipeline.
/// The first outbound SSH packet proves its handler is installed; all access is event-loop confined.
private final class SSHInitialReadGate: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    private var activated = false

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
        guard !activated else { return }
        activated = true
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { [channel = context.channel] _ in
            channel.close(promise: nil)
        }
    }
}

struct CitadelConnection: @unchecked Sendable {
    let client: SSHClient
    let lease: SSHRouteLease
    func close() async { await lease.close() }
}

private struct SSHClientBox: @unchecked Sendable { let value: SSHClient }

actor SSHRouteLease {
    private let agentAccess: SSHAgentAccess
    private let agentGroup: MultiThreadedEventLoopGroup?
    private var clients: [SSHClientBox] = []
    private var transport: Channel?
    private var closed = false
    private(set) var didTimeOut = false
    private var prompts: [UUID: Task<HostKeyDecision, Never>] = [:]
    private var closeHandlers: [@Sendable () async -> Void] = []

    init(agentAccess: SSHAgentAccess = SSHAgentAccess(), agentGroup: MultiThreadedEventLoopGroup? = nil) {
        self.agentAccess = agentAccess
        self.agentGroup = agentGroup
    }

    deinit {
        // Client authentication/host-key delegates retain the lease through their final
        // callbacks. Keep the executor alive until those clients and setup tasks are released,
        // not merely until their sockets close. Shutdown is asynchronous, including on NIO.
        agentGroup?.shutdownGracefully { _ in }
    }

    func onClose(_ handler: @escaping @Sendable () async -> Void) async {
        if closed { await handler() } else { closeHandlers.append(handler) }
    }

    func expire() async {
        didTimeOut = true
        await close()
    }

    func requestPrompt(_ check: HostKeyCheck, using prompt: @escaping HostKeyPromptHandler) async -> HostKeyDecision {
        guard !closed else { return .cancel }
        let id = UUID()
        let task = Task { await prompt(check) }
        prompts[id] = task
        defer { prompts.removeValue(forKey: id) }
        let decision = await task.value
        // A UI decision may already be queued when the route is closed or times out.
        // Never persist trust or resume authentication from that stale approval.
        guard !closed, !Task.isCancelled, !task.isCancelled else { return .cancel }
        return decision
    }

    func setTransport(_ channel: Channel) async throws {
        guard !closed else { try? await channel.close(); throw CancellationError() }
        transport = channel
    }

    fileprivate func add(_ client: SSHClientBox) async throws {
        guard !closed else { try? await client.value.close(); throw CancellationError() }
        clients.append(client)
        client.value.onDisconnect { [weak self] in Task { await self?.close() } }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        agentAccess.cancel()
        let handlers = closeHandlers
        closeHandlers = []
        for handler in handlers { await handler() }
        prompts.values.forEach { $0.cancel() }
        prompts = [:]
        let acquired = clients
        let socket = transport
        clients = []
        transport = nil
        // Closing the underlying transport also interrupts an unfinished forwarded handshake.
        try? await socket?.close()
        for client in acquired.reversed() { try? await client.value.close() }
    }
}

private struct AuthBox: @unchecked Sendable {
    let method: SSHAuthenticationMethod

    init(_ method: SSHAuthenticationMethod) {
        self.method = method
    }
}
