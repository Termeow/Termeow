@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOPosix

/// Forwarding belongs only to the destination terminal connection, never to its jump hosts or SFTP window.
actor SSHPortForwarding {
    private let connection: CitadelConnection
    private let onChange: @Sendable ([PortForwardStatus]) -> Void
    private var statuses: [PortForwardStatus]
    private var runs: [UUID: ForwardingRun] = [:]
    private var closed = false
    private var observingConnection = false

    init(connection: CitadelConnection, rules: [PortForwardRule], onChange: @escaping @Sendable ([PortForwardStatus]) -> Void) {
        self.connection = connection
        self.statuses = rules.map { PortForwardStatus(rule: $0, state: .stopped) }
        self.onChange = onChange
    }

    var snapshot: [PortForwardStatus] { statuses }

    func startEnabled() async {
        if let error = PortForwardRule.validationError(in: statuses.map(\.rule)) {
            for index in statuses.indices { statuses[index].state = .failed(error) }
            publish()
            return
        }
        for rule in statuses.map(\.rule).filter(\.isEnabled) { await start(rule.id) }
    }

    func start(_ id: UUID) async {
        if !observingConnection {
            observingConnection = true
            await connection.lease.onClose { [weak self] in await self?.shutdown() }
        }
        guard !closed, connection.client.isConnected, runs[id] == nil,
              let rule = statuses.first(where: { $0.id == id })?.rule else { return }
        if let error = rule.validationError { update(id, state: .failed(error)); return }
        let run = ForwardingRun()
        runs[id] = run
        update(id, state: .starting)
        if rule.kind == .remote {
            run.remoteTask = Task { [connection] in
                do {
                    try await connection.client.withRemotePortForward(host: rule.bindHost, port: rule.bindPort, onOpen: { _ in
                        guard await self.ready(id, token: run.token) else { throw CancellationError() }
                    }) { channel, _ in
                        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                            channel.pipeline.addHandlers(ForwardedSSHDataCodec(), SSHForwardingCloseGuard())
                        }.flatMapThrowing {
                            let stream = try PortForwardTransport.wrap(channel, lifetime: run.lifetime)
                            Task { await self.accept(stream, rule: rule, token: run.token) }
                        }
                    }
                } catch {
                    if Task.isCancelled {
                        if !(error is CancellationError) { await connection.close() }
                    } else {
                        self.fail(id, token: run.token, message: "Remote forwarding was rejected or the SSH connection closed.")
                    }
                }
            }
            run.deadline = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self.remoteStartTimedOut(id, token: run.token)
            }
        } else {
            do {
                let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let stream = try PortForwardTransport.wrap(channel, lifetime: run.lifetime)
                            Task { await self.accept(stream, rule: rule, token: run.token) }
                        }
                    }
                    .bind(host: rule.bindHost, port: rule.bindPort).get()
                guard run.lifetime.own(listener), runs[id]?.token == run.token else { return }
                listener.closeFuture.whenComplete { [weak self] _ in
                    Task { await self?.fail(id, token: run.token, message: "The listening socket closed.") }
                }
                _ = ready(id, token: run.token)
            } catch {
                fail(id, token: run.token, message: "Could not listen on \(rule.bindHost):\(rule.bindPort). Check the address, permissions, and whether the port is already in use.")
            }
        }
    }

    func stop(_ id: UUID) async {
        guard let run = runs[id] else { update(id, state: .stopped); return }
        guard !run.stopping else { return }
        run.stopping = true
        update(id, state: .stopping)
        run.deadline?.cancel()
        run.clients.values.forEach { $0.cancel() }
        await run.lifetime.closeAndWait()
        run.remoteTask?.cancel()
        if let remote = run.remoteTask {
            // If cancellation is not acknowledged, close SSH instead of leaving an unknown remote listener.
            let deadline = Task { [connection] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await connection.close()
            }
            await remote.value
            deadline.cancel()
        }
        guard runs[id]?.token == run.token else { return }
        runs.removeValue(forKey: id)
        update(id, state: .stopped)
    }

    func shutdown() {
        closed = true
        for run in runs.values {
            run.deadline?.cancel()
            run.lifetime.close()
            run.clients.values.forEach { $0.cancel() }
            run.remoteTask?.cancel()
        }
        runs = [:]
        for index in statuses.indices {
            if case .failed = statuses[index].state {} else { statuses[index].state = .stopped }
            statuses[index].connections = 0
        }
        publish()
    }

    private func ready(_ id: UUID, token: UUID) -> Bool {
        guard !closed, let run = runs[id], run.token == token, !run.stopping else { return false }
        run.deadline?.cancel()
        update(id, state: .listening)
        return true
    }

    private func remoteStartTimedOut(_ id: UUID, token: UUID) async {
        guard runs[id]?.token == token, statuses.first(where: { $0.id == id })?.state == .starting else { return }
        fail(id, token: token, message: "Remote forwarding timed out; SSH was closed to remove any pending listener.")
        await connection.close()
    }

    private func fail(_ id: UUID, token: UUID, message: String) {
        guard let run = runs[id], run.token == token, !run.stopping else { return }
        run.deadline?.cancel()
        run.lifetime.close()
        run.clients.values.forEach { $0.cancel() }
        runs.removeValue(forKey: id)
        update(id, state: .failed(message))
    }

    private func accept(_ stream: ForwardChannel, rule: PortForwardRule, token: UUID) {
        guard !closed, let run = runs[rule.id], run.token == token, !run.stopping, run.clients.count < 128 else {
            stream.channel.close(promise: nil)
            return
        }
        let clientID = UUID()
        let lifetime = ForwardingLifetime()
        guard lifetime.own(stream.channel) else { return }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            lifetime.close()
        }
        run.clients[clientID] = Task { [connection] in
            var message: String?
            await withTaskCancellationHandler {
                do {
                    try await PortForwardTransport.serve(stream, rule: rule, client: connection.client, lifetime: lifetime) { deadline.cancel() }
                } catch {
                    if !Task.isCancelled { message = "A forwarded connection failed. Check the destination and the SSH server's forwarding policy." }
                }
            } onCancel: { lifetime.close() }
            deadline.cancel()
            lifetime.close()
            self.clientFinished(rule.id, token: token, clientID: clientID, error: message)
        }
        updateConnections(rule.id, count: run.clients.count)
    }

    private func clientFinished(_ id: UUID, token: UUID, clientID: UUID, error: String?) {
        guard let run = runs[id], run.token == token else { return }
        run.clients.removeValue(forKey: clientID)
        if let index = statuses.firstIndex(where: { $0.id == id }), let error { statuses[index].lastError = error }
        updateConnections(id, count: run.clients.count)
    }

    private func updateConnections(_ id: UUID, count: Int) {
        if let index = statuses.firstIndex(where: { $0.id == id }) { statuses[index].connections = count }
        publish()
    }

    private func update(_ id: UUID, state: PortForwardState) {
        if let index = statuses.firstIndex(where: { $0.id == id }) {
            statuses[index].state = state
            if state == .starting { statuses[index].lastError = nil }
            if state == .stopped { statuses[index].connections = 0 }
        }
        publish()
    }

    private func publish() { onChange(statuses) }
}

/// Mutable task bookkeeping is accessed only by SSHPortForwarding; the token and lifetime are immutable.
private final class ForwardingRun: @unchecked Sendable {
    let token = UUID()
    let lifetime = ForwardingLifetime()
    var stopping = false
    var remoteTask: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var clients: [UUID: Task<Void, Never>] = [:]
}
