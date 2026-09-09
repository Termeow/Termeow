import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import TermeowKit

@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["TERMEOW_SSH_TEST_HOST"] != nil))
struct PortForwardLiveTests {
    private func connect(jump: Bool) async throws -> CitadelConnection {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(env["TERMEOW_SSH_TEST_HOST"])
        let user = try #require(env["TERMEOW_SSH_TEST_USER"])
        let secret = try #require(env["TERMEOW_SSH_TEST_PASSWORD"])
        let port = Int(env["TERMEOW_SSH_TEST_PORT"] ?? "22") ?? 22
        let outer = SessionProfile(name: "Test bastion", host: host, port: port, username: user)
        let target = jump ? SessionProfile(name: "Forward target", host: "127.0.0.1", port: port, username: user, jumpHostID: outer.id) : outer
        return try await CitadelConnectionFactory.connect(
            profile: target, secret: secret, hostKeyStore: isolatedRouteHostKeyStore(),
            jumpHosts: jump ? [SSHConnectionHop(profile: outer, secret: secret)] : []
        ) { _ in .connectOnce }
    }

    @Test(arguments: [false, true]) func allModesTransferDataAndStopIndependently(jump: Bool) async throws {
        let connection = try await connect(jump: jump)
        let echo = try await echoServer()
        let echoPort = try #require(echo.localAddress?.port)
        let remotePort = Int.random(in: 32_000...59_000)
        let localPort = try await unusedPort()
        var dynamicPort = try await unusedPort()
        while dynamicPort == localPort { dynamicPort = try await unusedPort() }
        let remote = PortForwardRule(kind: .remote, bindPort: remotePort, destinationPort: echoPort)
        let local = PortForwardRule(bindPort: localPort, destinationPort: remotePort)
        let dynamic = PortForwardRule(kind: .dynamic, bindPort: dynamicPort)
        let manager = SSHPortForwarding(connection: connection, rules: [remote, local, dynamic]) { _ in }
        do {
            await manager.startEnabled()
            try await waitUntilListening(manager)
            let payload = Array(repeating: UInt8(65), count: 1_048_576)
            let reply = try await exchange(port: localPort, bytes: payload)
            #expect(reply.count == payload.count)
            let payloadMatches = reply == payload
            #expect(payloadMatches)

            // Greeting, domain CONNECT request, and initial application data arrive in one stream.
            let request: [UInt8] = [5, 1, 0, 5, 1, 0, 3, 9] + Array("localhost".utf8)
                + [UInt8(remotePort >> 8), UInt8(remotePort & 255)]
            let proxyReply = try await exchange(port: dynamicPort, bytes: request + Array("proxy-payload".utf8))
            #expect(Array(proxyReply.prefix(2)) == [5, 0])
            #expect(Array(proxyReply.dropFirst(2).prefix(2)) == [5, 0])
            #expect(Array(proxyReply.dropFirst(12)) == Array("proxy-payload".utf8))

            try await withThrowingTaskGroup(of: Void.self) { group in
                for byte in UInt8(1)...UInt8(4) {
                    group.addTask {
                        let data = Array(repeating: byte, count: 131_072)
                        let response = try await exchange(port: localPort, bytes: data)
                        let matches = response == data
                        #expect(matches)
                    }
                }
                try await group.waitForAll()
            }

            // A conflicting listener must fail visibly without breaking the original tunnel or SSH.
            let conflict = SSHPortForwarding(connection: connection, rules: [PortForwardRule(bindPort: localPort)]) { _ in }
            await conflict.startEnabled()
            let conflictStatus = try #require(await conflict.snapshot.first)
            guard case .failed = conflictStatus.state else { Issue.record("Expected a bind conflict"); throw SSHError.connectionFailed }
            await conflict.shutdown()
            #expect(connection.client.isConnected)

            await manager.stop(local.id)
            await #expect(throws: (any Error).self) { _ = try await exchange(port: localPort, bytes: [1]) }
            await manager.start(local.id)
            #expect(try await exchange(port: localPort, bytes: [2, 3]) == [2, 3])

            await manager.stop(remote.id)
            #expect(connection.client.isConnected)
            let rejected = try await exchange(port: dynamicPort, bytes: request)
            #expect(Array(rejected.dropFirst(2).prefix(2)) == [5, 1])
            await manager.start(remote.id)
            try await waitUntilListening(manager)
            #expect(try await exchange(port: localPort, bytes: [4, 5]) == [4, 5])

            await manager.shutdown()
            await connection.close()
            #expect(!connection.client.isConnected)
            await #expect(throws: (any Error).self) { _ = try await exchange(port: dynamicPort, bytes: [5, 1, 0]) }
            try await echo.close()
        } catch {
            await manager.shutdown()
            await connection.close()
            try? await echo.close()
            throw error
        }
    }

    @Test func stoppedAndDisconnectedRulesClosePendingSOCKSConnections() async throws {
        let connection = try await connect(jump: false)
        let port = try await unusedPort()
        let rule = PortForwardRule(kind: .dynamic, bindPort: port)
        let manager = SSHPortForwarding(connection: connection, rules: [rule]) { _ in }
        do {
            await manager.startEnabled()
            try await waitUntilListening(manager)
            let pending = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connect(host: "127.0.0.1", port: port).get()
            try await pending.writeAndFlush(ByteBuffer(bytes: [5]))
            await manager.stop(rule.id)
            try await pending.closeFuture.get()
            await manager.start(rule.id)
            let another = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connect(host: "127.0.0.1", port: port).get()
            await connection.close()
            try await another.closeFuture.get()
            #expect(await manager.snapshot.allSatisfy { $0.state == .stopped })
            await #expect(throws: (any Error).self) { _ = try await exchange(port: port, bytes: [5]) }
        } catch {
            await manager.shutdown()
            await connection.close()
            throw error
        }
    }

    @Test func terminalSessionStartsControlsAndCleansUpItsRules() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = try await unusedPort()
        let rule = PortForwardRule(kind: .dynamic, bindPort: port)
        let profile = SessionProfile(name: "Forwarding terminal", host: try #require(env["TERMEOW_SSH_TEST_HOST"]),
            port: Int(env["TERMEOW_SSH_TEST_PORT"] ?? "22") ?? 22,
            username: try #require(env["TERMEOW_SSH_TEST_USER"]), keepAliveSeconds: 0, portForwards: [rule])
        let statuses = ForwardStatusCapture()
        let session = CitadelSSHSession(profile: profile, secret: try #require(env["TERMEOW_SSH_TEST_PASSWORD"]),
                                        hostKeyStore: isolatedRouteHostKeyStore()) { _ in .connectOnce }
        session.onPortForwardChange = { values in Task { await statuses.update(values) } }
        do {
            try await session.connect()
            #expect(session.state == .connected)
            #expect(try await exchange(port: port, bytes: [5, 1, 2]) == [5, 255])
            await session.stopPortForward(rule.id)
            await #expect(throws: (any Error).self) { _ = try await exchange(port: port, bytes: [5]) }
            await session.startPortForward(rule.id)
            #expect(try await exchange(port: port, bytes: [5, 1, 2]) == [5, 255])
            await session.disconnect()
            #expect(session.state == .disconnected)
            await #expect(throws: (any Error).self) { _ = try await exchange(port: port, bytes: [5]) }
            #expect(await statuses.sawListening)
        } catch { await session.disconnect(); throw error }
    }
}

private actor ForwardStatusCapture {
    var sawListening = false
    func update(_ values: [PortForwardStatus]) { sawListening = sawListening || values.contains { $0.state == .listening } }
}

private func waitUntilListening(_ manager: SSHPortForwarding) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        let statuses = await manager.snapshot
        if statuses.allSatisfy({ $0.state == .listening }) { return }
        if let failed = statuses.first(where: { if case .failed = $0.state { true } else { false } }) {
            Issue.record(Comment(rawValue: failed.state.title))
            throw SSHError.connectionFailed
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw SSHError.timeout
}

private func unusedPort() async throws -> Int {
    let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(listener.localAddress?.port)
    try await listener.close()
    return port
}

private func echoServer() async throws -> Channel {
    try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .childChannelInitializer { $0.pipeline.addHandler(EchoAfterEOF()) }
        .bind(host: "127.0.0.1", port: 0).get()
}

private func exchange(port: Int, bytes: [UInt8]) async throws -> [UInt8] {
    let lifetime = ForwardingLifetime()
    defer { lifetime.close() }
    let deadline = Task {
        do { try await Task.sleep(for: .seconds(12)) } catch { return }
        lifetime.close()
    }
    defer { deadline.cancel() }
    let channel = try await PortForwardTransport.tcp(host: "127.0.0.1", port: port, loop: MultiThreadedEventLoopGroup.singleton.next(), lifetime: lifetime)
    return try await channel.executeThenClose { inbound, outbound in
        try await outbound.write(ByteBuffer(bytes: bytes))
        outbound.finish()
        var result: [UInt8] = []
        for try await data in inbound { result.append(contentsOf: data.readableBytesView) }
        return result
    }
}

/// A response is deliberately withheld until EOF to catch premature full-close behavior in tunnels.
private final class EchoAfterEOF: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var accumulated = ByteBuffer()
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard accumulated.readableBytes + buffer.readableBytes <= 4_194_304 else { context.close(promise: nil); return }
        accumulated.writeBuffer(&buffer)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            let channel = context.channel
            channel.writeAndFlush(accumulated).whenComplete { _ in channel.close(promise: nil) }
        } else { context.fireUserInboundEventTriggered(event) }
    }
}
