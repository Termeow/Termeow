@preconcurrency import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH

public final class CitadelSSHSession: SSHSession, @unchecked Sendable {
    public var state: SSHConnectionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedState
    }

    public let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation
    public var onOutput: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (SSHConnectionState) -> Void)?
    public var onPortForwardChange: (@Sendable ([PortForwardStatus]) -> Void)?

    private let profile: SessionProfile
    private let secret: String
    private let hostKeyStore: HostKeyStore
    private let prompt: HostKeyPromptHandler
    private let jumpHosts: [SSHConnectionHop]

    private var client: SSHClient?
    private var connection: CitadelConnection?
    private var forwarding: SSHPortForwarding?
    private var writer: TTYStdinWriter?
    private var ptyTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var routeTask: Task<CitadelConnection, Error>?
    private var connectCompletion: SSHConnectCompletion?
    private let stateLock = NSLock()
    private var storedState: SSHConnectionState = .disconnected

    public init(
        profile: SessionProfile,
        secret: String,
        hostKeyStore: HostKeyStore,
        jumpHosts: [SSHConnectionHop] = [],
        prompt: @escaping HostKeyPromptHandler
    ) {
        self.profile = profile
        self.secret = secret
        self.hostKeyStore = hostKeyStore
        self.prompt = prompt
        self.jumpHosts = jumpHosts
        let pair = AsyncStream<Data>.makeStream()
        self.output = pair.stream
        self.outputContinuation = pair.continuation
    }

    public func connect() async throws {
        try await withTaskCancellationHandler {
            try await openConnection()
        } onCancel: { Task { await self.disconnect() } }
    }

    private func openConnection() async throws {
        try Task.checkCancellation()
        guard state == .disconnected || isFailed else {
            return
        }
        transition(to: .connecting)

        do {
            let task = Task {
                try await CitadelConnectionFactory.connect(
                    profile: profile, secret: secret, hostKeyStore: hostKeyStore,
                    jumpHosts: jumpHosts, prompt: prompt
                )
            }
            routeTask = task
            let connection = try await task.value
            routeTask = nil
            guard !Task.isCancelled, state == .connecting else {
                await connection.close()
                throw CancellationError()
            }
            self.connection = connection
            let client = connection.client
            self.client = client
            let forwarding = SSHPortForwarding(connection: connection, rules: profile.portForwards) { [weak self] statuses in
                self?.onPortForwardChange?(statuses)
            }
            self.forwarding = forwarding

            let request = ptyRequest
            let startup = profile.startupCommand
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = SSHConnectCompletion(continuation)
                connectCompletion = completion
                ptyTask = Task { [weak self] in
                    guard let self else { completion.finish(.failure(CancellationError())); return }
                    do {
                        try await client.withPTY(request) { inbound, outbound in
                            guard !Task.isCancelled else { throw CancellationError() }
                            self.attach(writer: outbound, completion: completion)
                            if !startup.isEmpty {
                                try await outbound.write(ByteBuffer(string: startup + "\n"))
                            }
                            for try await item in inbound {
                                let buffer: ByteBuffer
                                switch item {
                                case .stdout(let bytes), .stderr(let bytes):
                                    buffer = bytes
                                }
                                if let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                                    if let onOutput = self.onOutput {
                                        onOutput(data)
                                    } else {
                                        self.outputContinuation.yield(data)
                                    }
                                }
                            }
                        }
                        completion.finish(.failure(SSHError.connectionClosed))
                        await self.markDisconnected()
                    } catch {
                        await self.failConnect(error, completion: completion)
                    }
                }
            }
            if state == .connected, !Task.isCancelled { await forwarding.startEnabled() }
            AppLog.ssh.info("SSH session connected")
        } catch {
            routeTask = nil
            await forwarding?.shutdown()
            forwarding = nil
            await connection?.close()
            connection = nil
            client = nil
            if error is CancellationError { transition(to: .disconnected); throw error }
            transition(to: .failed(CitadelConnectionFactory.mapError(error)))
            AppLog.ssh.error("SSH connect failed")
            throw CitadelConnectionFactory.mapError(error)
        }
    }

    public func disconnect() async {
        routeTask?.cancel()
        routeTask = nil
        connectCompletion?.finish(.failure(CancellationError()))
        connectCompletion = nil
        stopKeepAlive()
        ptyTask?.cancel()
        ptyTask = nil
        writer = nil
        await forwarding?.shutdown()
        forwarding = nil
        await connection?.close()
        connection = nil
        client = nil
        transition(to: .disconnected)
        AppLog.ssh.info("SSH session disconnected")
    }

    public func send(_ data: Data) async throws {
        guard let writer else { throw SSHError.connectionClosed }
        try await writer.write(ByteBuffer(data: data))
    }

    public func resize(cols: Int, rows: Int) async throws {
        guard let writer else { return }
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    public func startPortForward(_ id: UUID) async {
        guard state == .connected else { return }
        await forwarding?.start(id)
    }

    public func stopPortForward(_ id: UUID) async { await forwarding?.stop(id) }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var ptyRequest: SSHChannelRequestEvent.PseudoTerminalRequest {
        SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: profile.term.isEmpty ? "xterm-256color" : profile.term,
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )
    }

    private func attach(writer: TTYStdinWriter, completion: SSHConnectCompletion) {
        self.writer = writer
        startKeepAlive(using: writer)
        transition(to: .connected)
        completion.finish(.success(()))
    }

    private func failConnect(_ error: Error, completion: SSHConnectCompletion) async {
        stopKeepAlive()
        writer = nil
        await forwarding?.shutdown()
        forwarding = nil
        await connection?.close()
        connection = nil
        client = nil
        let mapped = CitadelConnectionFactory.mapError(error)
        completion.finish(.failure(error is CancellationError ? CancellationError() : mapped))
        if Task.isCancelled || error is CancellationError || mapped == .connectionClosed {
            transition(to: .disconnected)
        } else {
            transition(to: .failed(mapped))
        }
    }

    private func markDisconnected() async {
        stopKeepAlive()
        writer = nil
        await forwarding?.shutdown()
        forwarding = nil
        await connection?.close()
        connection = nil
        client = nil
        transition(to: .disconnected)
    }

    private func transition(to newState: SSHConnectionState) {
        stateLock.lock()
        let changed = storedState != newState
        storedState = newState
        stateLock.unlock()
        if changed {
            onStateChange?(newState)
        }
    }

    private func startKeepAlive(using writer: TTYStdinWriter) {
        stopKeepAlive()
        let intervalSeconds = profile.keepAliveSeconds
        guard intervalSeconds > 0 else { return }

        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(intervalSeconds))
                } catch {
                    return
                }
                guard self != nil, !Task.isCancelled else { return }
                do {
                    // An empty SSH channel-data packet keeps the transport active without writing bytes to the shell.
                    try await writer.write(ByteBuffer())
                } catch {
                    return
                }
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

}

/// PTY readiness and cancellation can race; a checked continuation must be completed exactly once.
private final class SSHConnectCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
