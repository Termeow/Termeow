import NIO
@preconcurrency import NIOSSH

/// Owns a child channel until setup succeeds. All mutable state is event-loop confined.
final class SSHChannelSetup<Value>: @unchecked Sendable {
    private let eventLoop: EventLoop
    private let completion: EventLoopPromise<Value>
    private var channel: Channel?
    private var timer: Scheduled<Void>?
    private var completed = false

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
        self.completion = eventLoop.makePromise()
    }

    func register(_ channel: Channel) -> Bool {
        eventLoop.preconditionInEventLoop()
        guard !completed else {
            channel.close(promise: nil)
            return false
        }
        self.channel = channel
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.finish(.failure(ChannelError.ioOnClosedChannel))
        }
        return true
    }

    func run(
        timeout: TimeAmount,
        operation: @escaping @Sendable (SSHChannelSetup<Value>) -> EventLoopFuture<Value>
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            eventLoop.execute {
                guard !self.completed else { return }
                self.timer = self.eventLoop.scheduleTask(in: timeout) {
                    self.finish(.failure(ChannelError.connectTimeout(timeout)))
                }
                operation(self).whenComplete { self.finish($0) }
            }
            return try await completion.futureResult.get()
        } onCancel: {
            self.eventLoop.execute { self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        eventLoop.preconditionInEventLoop()
        guard !completed else { return }
        completed = true
        timer?.cancel()
        timer = nil
        if case .failure = result { channel?.close(promise: nil) }
        channel = nil
        completion.completeWith(result)
    }
}

/// SSH request write completion is not a CHANNEL_SUCCESS acknowledgement.
/// Send setup requests sequentially so each reply belongs to exactly one request.
final class SSHChannelRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    private var pending: EventLoopPromise<Void>?
    private var closed = false

    func request(_ event: Any, wantReply: Bool = true, on channel: Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.preconditionInEventLoop()
        guard !closed, channel.isActive else {
            return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
        }
        precondition(pending == nil, "Setup requests must be serialized")
        let written = channel.eventLoop.makePromise(of: Void.self)
        let reply = wantReply ? channel.eventLoop.makePromise(of: Void.self) : written
        if wantReply { pending = reply }
        written.futureResult.whenFailure { error in self.fail(error) }
        channel.triggerUserOutboundEvent(event, promise: written)
        return reply.futureResult
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent where pending != nil:
            let reply = pending
            pending = nil
            reply?.succeed(())
        case is ChannelFailureEvent where pending != nil:
            fail(CitadelError.channelFailure)
        case ChannelEvent.inputClosed:
            fail(ChannelError.eof)
            context.fireUserInboundEventTriggered(event)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(ChannelError.ioOnClosedChannel)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        fail(ChannelError.ioOnClosedChannel)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.fireErrorCaught(error)
    }

    private func fail(_ error: Error) {
        closed = true
        let reply = pending
        pending = nil
        reply?.fail(error)
    }
}
