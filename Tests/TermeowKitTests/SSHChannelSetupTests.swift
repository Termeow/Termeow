@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Testing
@testable import TermeowKit

/// Loopback protocol fixtures only: no external SSH server, shell, agent, or user files.
@Suite(.serialized, .timeLimit(.minutes(1)))
private struct SSHChannelSetupTests {
    @Test(arguments: [SetupStage.channel, .pty, .shell])
    func terminalSetupTimesOutWithoutReportingConnected(stage: SetupStage) async throws {
        try await withSetupServer(.stall(stage)) { server in
            let session = server.terminal()
            let started = ContinuousClock.now
            await #expect(throws: SSHError.timeout) {
                try await boundedSetup(stop: { await session.disconnect() }) { try await session.connect() }
            }
            #expect(started.duration(to: .now) < .seconds(3))
            #expect(session.state == .failed(.timeout))
            #expect(server.state.inputs.isEmpty)
            if stage == .pty { #expect(!server.state.events.contains(.shell)) }
            try await server.waitForClosedConnections()
            await session.disconnect()
        }
    }

    @Test(arguments: [SetupStage.subsystem, .version, .realpath])
    func sftpSetupTimeoutIncludesVersionAndHomeDirectory(stage: SetupStage) async throws {
        try await withSetupServer(.stall(stage)) { server in
            let service = server.sftp()
            await #expect(throws: SSHError.timeout) {
                _ = try await boundedSetup(stop: { await service.disconnect() }) { try await service.connect() }
            }
            #expect(server.state.events.contains(stage))
            if stage == .subsystem { #expect(!server.state.events.contains(.version)) }
            try await server.waitForClosedConnections()
            // A failed initialization must not poison the next connection attempt.
            server.state.behavior = .normal
            #expect(try await boundedSetup(stop: { await service.disconnect() }) { try await service.connect() } == "/test-home")
            await service.disconnect()
        }
    }

    @Test(arguments: [SetupStage.pty, .shell, .subsystem])
    func rejectedRequestsFailBeforeAnyInputIsSent(stage: SetupStage) async throws {
        try await withSetupServer(.reject(stage)) { server in
            let session = server.terminal()
            let service = server.sftp()
            let started = ContinuousClock.now
            do {
                try await boundedSetup(stop: { await session.disconnect(); await service.disconnect() }) {
                    if stage == .subsystem { _ = try await service.connect() }
                    else { try await session.connect() }
                }
                Issue.record("A rejected setup request must fail")
            } catch {
                #expect(!(error is SetupTestError))
                #expect(CitadelConnectionFactory.mapError(error) == .connectionFailed)
            }
            #expect(started.duration(to: .now) < .seconds(1))
            #expect(server.state.inputs.isEmpty)
            if stage == .pty { #expect(!server.state.events.contains(.shell)) }
            try await server.waitForClosedConnections()
            await session.disconnect()
            await service.disconnect()
        }
    }

    @Test(arguments: [SetupStage.channel, .pty, .shell, .subsystem, .version, .realpath])
    func serverClosureDuringSetupFinishesPromptly(stage: SetupStage) async throws {
        try await withSetupServer(.close(stage)) { server in
            let session = server.terminal(timeout: 5)
            let service = server.sftp(timeout: 5)
            let started = ContinuousClock.now
            do {
                try await boundedSetup(stop: { await session.disconnect(); await service.disconnect() }) {
                    if stage.isSFTP { _ = try await service.connect() }
                    else { try await session.connect() }
                }
                Issue.record("Closing during setup must fail")
            } catch {
                #expect(!(error is SetupTestError))
                #expect(CitadelConnectionFactory.mapError(error) != .timeout)
            }
            #expect(started.duration(to: .now) < .seconds(1))
            try await server.waitForClosedConnections()
            await session.disconnect()
            await service.disconnect()
        }
    }

    @Test(arguments: [SetupStage.channel, .pty, .shell, .subsystem, .version, .realpath])
    func cancellingSetupClosesPendingRequests(stage: SetupStage) async throws {
        try await withSetupServer(.stall(stage)) { server in
            let session = server.terminal(timeout: 5)
            let service = server.sftp(timeout: 5)
            let task = Task {
                if stage.isSFTP { _ = try await service.connect() }
                else { try await session.connect() }
            }
            try await server.state.waitFor(stage)
            let started = ContinuousClock.now
            task.cancel()
            await #expect(throws: CancellationError.self) {
                try await boundedSetup(stop: { await session.disconnect(); await service.disconnect() }) { try await task.value }
            }
            #expect(started.duration(to: .now) < .seconds(1))
            try await server.waitForClosedConnections()
            await session.disconnect()
            await service.disconnect()
        }
    }

    @Test func terminalWaitsForBothRepliesAndRetainsImmediateOutput() async throws {
        try await withSetupServer(.delay(.milliseconds(150))) { server in
            let session = server.terminal()
            let task = Task { try await session.connect() }
            try await server.state.waitFor(.pty)
            #expect(session.state == .connecting)
            await #expect(throws: SSHError.connectionClosed) { try await session.send(Data([42])) }
            try await server.state.waitFor(.shell)
            #expect(session.state == .connecting)
            #expect(server.state.inputs.isEmpty)
            try await boundedSetup(stop: { await session.disconnect() }) { try await task.value }
            #expect(session.state == .connected)
            let output = try await boundedSetup(stop: { await session.disconnect() }) {
                var result = ""
                for await data in session.output {
                    result += String(decoding: data, as: UTF8.self)
                    if result.contains("startup-marker") { return result }
                }
                throw SSHError.connectionClosed
            }
            #expect(output.contains("ready-before-callback"))
            #expect(server.state.inputs == ["startup-marker\n"])
            try await Task.sleep(for: .milliseconds(1100))
            #expect(session.state == .connected)
            try await session.send(Data("still-connected".utf8))
            await session.disconnect()
            // A successful setup's cancelled deadline must not affect a new channel.
            try await boundedSetup(stop: { await session.disconnect() }) { try await session.connect() }
            #expect(session.state == .connected)
            await session.disconnect()
        }
    }

    @Test func sftpHasOneInitializationBudgetAndDoesNotExpireAfterSuccess() async throws {
        // Three delayed responses together exceed the one-second budget.
        try await withSetupServer(.delay(.milliseconds(400))) { server in
            let service = server.sftp()
            await #expect(throws: SSHError.timeout) {
                _ = try await boundedSetup(stop: { await service.disconnect() }) { try await service.connect() }
            }
            #expect(server.state.events.contains(.realpath))
            server.state.behavior = .normal
            #expect(try await boundedSetup(stop: { await service.disconnect() }) { try await service.connect() } == "/test-home")
            try await Task.sleep(for: .milliseconds(1100))
            #expect(try await service.connect() == "/test-home")
            // The already-connected fast path also bounds its directory request.
            server.state.behavior = .stall(.realpath)
            await #expect(throws: SSHError.timeout) {
                _ = try await boundedSetup(stop: { await service.disconnect() }) { try await service.connect() }
            }
            try await server.waitForClosedConnections()
            await service.disconnect()
        }
    }

    @Test func environmentRepliesCannotPrematurelyStartTheShell() async throws {
        try await withSetupServer(.delay(.milliseconds(60))) { server in
            let connection = try await server.connection()
            do {
                let environments = [
                    SSHChannelRequestEvent.EnvironmentRequest(wantReply: true, name: "FIRST", value: "1"),
                    SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "SECOND", value: "2"),
                    SSHChannelRequestEvent.EnvironmentRequest(wantReply: true, name: "THIRD", value: "3"),
                ]
                let stream = try await connection.client.executeCommandStream("command-marker", environment: environments, inShell: true)
                for try await _ in stream {}
                #expect(server.state.inputs == ["command-marker;exit\n"])
                #expect(server.state.events.prefix(5) == [.channel, .environment, .environment, .environment, .shell])
                #expect(!server.state.prematureInput)
                await connection.close()
            } catch { await connection.close(); throw error }
        }
    }

    @Test(arguments: [SetupStage.channel, .subsystem, .version])
    func citadelSFTPDeadlineClosesOnlyThePendingChild(stage: SetupStage) async throws {
        try await withSetupServer(.stall(stage)) { server in
            let connection = try await server.connection()
            do {
                do {
                    _ = try await boundedSetup(stop: { await connection.close() }) {
                        try await connection.client.openSFTP(setupTimeout: .milliseconds(200))
                    }
                    Issue.record("The Citadel setup deadline must include version negotiation")
                } catch {
                    #expect(!(error is SetupTestError))
                    #expect(CitadelConnectionFactory.mapError(error) == .timeout)
                }
                #expect(connection.client.isConnected)
                server.state.behavior = .normal
                let sftp = try await connection.client.openSFTP(setupTimeout: .seconds(1))
                #expect(try await sftp.getRealPath(atPath: ".") == "/test-home")
                try await sftp.close()
                await connection.close()
            } catch { await connection.close(); throw error }
        }
    }

    @Test func cancellingCitadelSFTPSetupPreservesTheAuthenticatedTransport() async throws {
        try await withSetupServer(.stall(.version)) { server in
            let connection = try await server.connection()
            do {
                let task = Task { try await connection.client.openSFTP() }
                try await server.state.waitFor(.version)
                task.cancel()
                await #expect(throws: CancellationError.self) {
                    _ = try await boundedSetup(stop: { await connection.close() }) { try await task.value }
                }
                #expect(connection.client.isConnected)
                server.state.behavior = .normal
                let sftp = try await connection.client.openSFTP(setupTimeout: .seconds(1))
                #expect(try await sftp.getRealPath(atPath: ".") == "/test-home")
                try await sftp.close()
                await connection.close()
            } catch { await connection.close(); throw error }
        }
    }
}

private enum SetupTestError: Error { case watchdog, missingEvent }
private enum SetupStage: Sendable {
    case channel, environment, pty, shell, subsystem, version, realpath
    var isSFTP: Bool { self == .subsystem || self == .version || self == .realpath }
}
private enum SetupBehavior: Sendable {
    case normal, stall(SetupStage), reject(SetupStage), close(SetupStage), delay(TimeAmount)
}

/// Independent watchdog: a broken product timeout cannot leave the test suspended.
private func boundedSetup<Value: Sendable>(
    stop: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            await stop()
            throw SetupTestError.watchdog
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private final class SetupServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBehavior: SetupBehavior
    private var storedEvents: [SetupStage] = []
    private var storedInputs: [String] = []
    private var storedChannels: [Channel] = []
    private var storedPrematureInput = false

    init(_ behavior: SetupBehavior) { storedBehavior = behavior }
    var behavior: SetupBehavior {
        get { lock.withLock { storedBehavior } }
        set { lock.withLock { storedBehavior = newValue } }
    }
    var events: [SetupStage] { lock.withLock { storedEvents } }
    var inputs: [String] { lock.withLock { storedInputs } }
    var channels: [Channel] { lock.withLock { storedChannels } }
    var prematureInput: Bool { lock.withLock { storedPrematureInput } }
    func own(_ channel: Channel) { lock.withLock { storedChannels.append(channel) } }
    func record(_ stage: SetupStage) { lock.withLock { storedEvents.append(stage) } }
    func recordInput(_ input: String, ready: Bool) {
        lock.withLock { storedInputs.append(input); storedPrematureInput = storedPrematureInput || !ready }
    }
    func waitFor(_ stage: SetupStage) async throws {
        for _ in 0..<200 {
            if events.contains(stage) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SetupTestError.missingEvent
    }
}

private struct SetupServer: Sendable {
    let channel: Channel
    let state: SetupServerState
    func profile(timeout: Int = 1) -> SessionProfile {
        SessionProfile(name: "Setup test", host: "127.0.0.1", port: channel.localAddress!.port!, username: "setup-test",
                       startupCommand: "startup-marker", keepAliveSeconds: 0, timeoutSeconds: timeout)
    }
    func terminal(timeout: Int = 1) -> CitadelSSHSession {
        CitadelSSHSession(profile: profile(timeout: timeout), secret: "test-only", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
    }
    func sftp(timeout: Int = 1) -> CitadelSFTPService {
        CitadelSFTPService(profile: profile(timeout: timeout), secret: "test-only", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
    }
    func connection() async throws -> CitadelConnection {
        try await CitadelConnectionFactory.connect(profile: profile(), secret: "test-only", hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
    }
    func waitForClosedConnections() async throws {
        for _ in 0..<100 {
            if state.channels.allSatisfy({ !$0.isActive }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.channels.allSatisfy { !$0.isActive })
    }
}

private final class SetupServerAuth: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if request.username == "setup-test", case .password(let password) = request.request, password.password == "test-only" {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}

private func withSetupServer<Value: Sendable>(
    _ behavior: SetupBehavior,
    body: @Sendable (SetupServer) async throws -> Value
) async throws -> Value {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let state = SetupServerState(behavior)
    let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    let listener: Channel
    do {
        listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            state.own(channel)
            return channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [hostKey], userAuthDelegate: SetupServerAuth())), allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, _ in
                        state.own(child)
                        state.record(.channel)
                        if case .stall(.channel) = state.behavior {
                            let pending = child.eventLoop.makePromise(of: Void.self)
                            child.closeFuture.whenComplete { _ in pending.fail(ChannelError.ioOnClosedChannel) }
                            return pending.futureResult
                        }
                        if case .close(.channel) = state.behavior {
                            return child.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                        }
                        return child.pipeline.addHandler(SetupSubsystem(state: state))
                    }
                ))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
    } catch { try await group.shutdownGracefully(); throw error }
    let result: Result<Value, Error>
    do { result = .success(try await body(SetupServer(channel: listener, state: state))) }
    catch { result = .failure(error) }
    for channel in state.channels { try? await channel.close() }
    try await listener.close()
    try await group.shutdownGracefully()
    return try result.get()
}

private final class SetupSubsystem: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let state: SetupServerState
    var sftp = false
    var shellReady = false
    var pending = ByteBuffer()
    init(state: SetupServerState) { self.state = state }

    func respond(_ stage: SetupStage, channel: Channel, body: @escaping @Sendable () -> Void) {
        state.record(stage)
        switch state.behavior {
        case .stall(stage): return
        case .reject(stage): channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
        case .close(stage): channel.close(promise: nil)
        case .delay(let delay):
            channel.eventLoop.scheduleTask(in: delay) { if channel.isActive { body() } }
        default: body()
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        let channel = context.channel
        switch event {
        case let request as SSHChannelRequestEvent.EnvironmentRequest:
            respond(.environment, channel: channel) {
                if request.wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            }
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            respond(.pty, channel: channel) {
                if request.wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            }
        case is SSHChannelRequestEvent.ShellRequest:
            respond(.shell, channel: channel) {
                self.shellReady = true
                channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                self.write(ByteBuffer(string: "ready-before-callback\n"), channel: channel)
            }
        case is SSHChannelRequestEvent.SubsystemRequest:
            sftp = true
            respond(.subsystem, channel: channel) { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        default: context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(var bytes) = unwrapInboundIn(data).data else { return }
        let channel = context.channel
        if !sftp {
            let input = String(buffer: bytes)
            state.recordInput(input, ready: shellReady)
            write(bytes, channel: channel)
            if input.hasSuffix(";exit\n") {
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
                channel.close(promise: nil)
            }
            return
        }
        pending.writeBuffer(&bytes)
        while let length = pending.getInteger(at: pending.readerIndex, as: UInt32.self), length < 65_536,
              pending.readableBytes >= 4 + Int(length) {
            pending.moveReaderIndex(forwardBy: 4)
            guard var packet = pending.readSlice(length: Int(length)), let type = packet.readInteger(as: UInt8.self) else { return }
            if type == 1 {
                respond(.version, channel: channel) {
                    var response = ByteBuffer()
                    response.writeInteger(UInt8(2)); response.writeInteger(UInt32(3))
                    self.writeSFTP(response, channel: channel)
                }
            } else if type == 16, let requestID = packet.readInteger(as: UInt32.self) {
                respond(.realpath, channel: channel) {
                    var response = ByteBuffer()
                    response.writeInteger(UInt8(104)); response.writeInteger(requestID); response.writeInteger(UInt32(1))
                    for _ in 0..<2 {
                        response.writeInteger(UInt32("/test-home".utf8.count)); response.writeString("/test-home")
                    }
                    response.writeInteger(UInt32(0))
                    self.writeSFTP(response, channel: channel)
                }
            }
        }
    }

    func writeSFTP(_ payload: ByteBuffer, channel: Channel) {
        var frame = ByteBuffer()
        frame.writeInteger(UInt32(payload.readableBytes)); frame.writeImmutableBuffer(payload)
        write(frame, channel: channel)
    }
    func write(_ bytes: ByteBuffer, channel: Channel) {
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bytes)), promise: nil)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
