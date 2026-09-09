@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

typealias ForwardChannel = NIOAsyncChannel<ByteBuffer, ByteBuffer>

/// Own pending opens as well as established streams, so stopping a rule cannot leak a late channel.
final class ForwardingLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var channels: [ObjectIdentifier: Channel] = [:]

    func own(_ channel: Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        lock.lock()
        let accept = !closed && channels.count < 129
        if accept { channels[id] = channel }
        lock.unlock()
        guard accept else { channel.close(promise: nil); return false }
        channel.closeFuture.whenComplete { [weak self] _ in self?.remove(id) }
        return true
    }

    private func remove(_ id: ObjectIdentifier) {
        lock.lock(); channels.removeValue(forKey: id); lock.unlock()
    }

    @discardableResult
    func close() -> [Channel] {
        lock.lock()
        closed = true
        let owned = Array(channels.values)
        channels = [:]
        lock.unlock()
        for channel in owned {
            channel.triggerUserOutboundEvent(AbortForwarding(), promise: nil)
            channel.close(promise: nil)
        }
        return owned
    }

    func closeAndWait() async {
        for channel in close() { try? await channel.closeFuture.get() }
    }
}

enum PortForwardTransport {
    static func wrap(_ channel: Channel, lifetime: ForwardingLifetime) throws -> ForwardChannel {
        guard lifetime.own(channel) else { throw CancellationError() }
        return try ForwardChannel(wrappingChannelSynchronously: channel, configuration: .init(isOutboundHalfClosureEnabled: true))
    }

    static func tcp(host: String, port: Int, loop: EventLoop, lifetime: ForwardingLifetime) async throws -> ForwardChannel {
        try await ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connectTimeout(.seconds(10))
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture { try wrap(channel, lifetime: lifetime) }
            }
    }

    static func direct(client: SSHClient, host: String, port: Int, origin: SocketAddress?, lifetime: ForwardingLifetime) async throws -> ForwardChannel {
        let box = ForwardChannelBox()
        let channel = try await client.createDirectTCPIPChannel(using: .init(
            targetHost: host, targetPort: port,
            originatorAddress: origin ?? (try SocketAddress(ipAddress: "127.0.0.1", port: 0))
        )) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(SSHForwardingCloseGuard())
                box.value = try wrap(channel, lifetime: lifetime)
            }
        }
        guard let stream = box.value else { channel.close(promise: nil); throw SSHError.connectionFailed }
        return stream
    }

    static func serve(_ source: ForwardChannel, rule: PortForwardRule, client: SSHClient, lifetime: ForwardingLifetime,
                      onReady: @escaping @Sendable () -> Void) async throws {
        try await source.executeThenClose { inbound, outbound in
            var iterator = inbound.makeAsyncIterator()
            var leftover = ByteBuffer()
            var host = rule.destinationHost
            var port = rule.destinationPort
            if rule.kind == .dynamic {
                var parser = SOCKS5Handshake()
                var destination: (String, Int)?
                do {
                    while destination == nil {
                        if let message = try parser.next(from: &leftover) {
                            switch message {
                            case .reply(let bytes): try await outbound.write(ByteBuffer(bytes: bytes))
                            case .connect(let target, let targetPort): destination = (target, targetPort)
                            }
                        } else {
                            guard var data = try await iterator.next() else { return }
                            guard leftover.readableBytes + data.readableBytes <= 65_536 else { throw SOCKS5Failure(code: 1) }
                            leftover.writeBuffer(&data)
                        }
                    }
                } catch let error as SOCKS5Failure {
                    try await outbound.write(ByteBuffer(bytes: error.reply))
                    return
                }
                guard let destination else { return }
                (host, port) = destination
            }

            let peer: ForwardChannel
            do {
                if rule.kind == .remote {
                    peer = try await tcp(host: host, port: port, loop: source.channel.eventLoop, lifetime: lifetime)
                } else {
                    peer = try await direct(client: client, host: host, port: port, origin: source.channel.remoteAddress, lifetime: lifetime)
                }
            } catch {
                if rule.kind == .dynamic { try? await outbound.write(ByteBuffer(bytes: SOCKS5Failure(code: 1).reply)) }
                throw error
            }
            if rule.kind == .dynamic {
                try await outbound.write(ByteBuffer(bytes: [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
            }
            onReady()
            try await peer.executeThenClose { peerInbound, peerOutbound in
                // Preserve half-close semantics: EOF in one direction must not truncate the response.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await data in peerInbound { try await outbound.write(data) }
                            outbound.finish()
                        } catch { source.channel.close(promise: nil); throw error }
                    }
                    do {
                        if leftover.readableBytes > 0 { try await peerOutbound.write(leftover) }
                        while let data = try await iterator.next() { try await peerOutbound.write(data) }
                        peerOutbound.finish()
                        try await group.waitForAll()
                    } catch {
                        peer.channel.close(promise: nil)
                        group.cancelAll()
                        throw error
                    }
                }
            }
        }
    }
}

/// Written once by the SSH channel initializer and read after its channel-open future completes.
private final class ForwardChannelBox: @unchecked Sendable { var value: ForwardChannel? }

final class ForwardedSSHDataCodec: ChannelDuplexHandler, Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let bytes) = packet.data else {
            context.close(promise: nil); return
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

/// The currently pinned NIOSSH fork rejects sending EOF after receiving EOF.
/// Once both application directions finish, drain writes and send CLOSE instead of a second EOF.
final class SSHForwardingCloseGuard: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    private var receivedEOF = false
    private var sentEOF = false
    private var gracefulClose: EventLoopFuture<Void>?

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if event is AbortForwarding {
            // An explicit stop must not wait for a slow peer to drain buffered writes.
            context.close(mode: .all, promise: promise)
        } else { context.triggerUserOutboundEvent(event, promise: promise) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed { receivedEOF = true }
        context.fireUserInboundEventTriggered(event)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if let gracefulClose { gracefulClose.cascade(to: promise); return }
        guard mode == .output else { context.close(mode: mode, promise: promise); return }
        guard !sentEOF else { promise?.succeed(()); return }
        sentEOF = true
        guard receivedEOF else { context.close(mode: .output, promise: promise); return }
        let completion = context.eventLoop.makePromise(of: Void.self)
        gracefulClose = completion.futureResult
        completion.futureResult.cascade(to: promise)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(ByteBuffer())).whenComplete { _ in
            boundContext.value.close(mode: .all, promise: completion)
        }
    }
}

private struct AbortForwarding: Sendable {}
