@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

public final class CitadelSSHSession: SSHSession, @unchecked Sendable {
    public private(set) var state: SSHConnectionState = .disconnected

    public let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation
    public var onOutput: (@Sendable (Data) -> Void)?

    private let profile: SessionProfile
    private let secret: String
    private let hostKeyStore: HostKeyStore
    private let prompt: HostKeyPromptHandler

    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var ptyTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var connectResumed = false

    public init(
        profile: SessionProfile,
        secret: String,
        hostKeyStore: HostKeyStore,
        prompt: @escaping HostKeyPromptHandler
    ) {
        self.profile = profile
        self.secret = secret
        self.hostKeyStore = hostKeyStore
        self.prompt = prompt
        let pair = AsyncStream<Data>.makeStream()
        self.output = pair.stream
        self.outputContinuation = pair.continuation
    }

    public func connect() async throws {
        guard state == .disconnected || isFailed else {
            return
        }
        state = .connecting
        connectResumed = false

        do {
            let auth = AuthBox(try authenticationMethod())
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

            let client = try await SSHClient.connect(to: settings)
            self.client = client

            let request = ptyRequest
            let startup = profile.startupCommand
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ptyTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await client.withPTY(request) { inbound, outbound in
                            self.attach(writer: outbound, continuation: continuation)
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
                        self.markDisconnected()
                    } catch {
                        self.failConnect(error, continuation: continuation)
                    }
                }
            }
            state = .connected
            AppLog.ssh.info("SSH session connected")
        } catch {
            state = .failed(mapError(error))
            AppLog.ssh.error("SSH connect failed")
            throw mapError(error)
        }
    }

    public func disconnect() async {
        stopKeepAlive()
        ptyTask?.cancel()
        ptyTask = nil
        writer = nil
        if let client {
            try? await client.close()
        }
        client = nil
        state = .disconnected
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

    private func attach(writer: TTYStdinWriter, continuation: CheckedContinuation<Void, Error>) {
        self.writer = writer
        startKeepAlive(using: writer)
        if !connectResumed {
            connectResumed = true
            continuation.resume()
        }
    }

    private func failConnect(_ error: Error, continuation: CheckedContinuation<Void, Error>) {
        stopKeepAlive()
        if !connectResumed {
            connectResumed = true
            continuation.resume(throwing: mapError(error))
        } else {
            state = .failed(mapError(error))
        }
    }

    private func markDisconnected() {
        stopKeepAlive()
        writer = nil
        if state == .connected {
            state = .disconnected
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

    private func authenticationMethod() throws -> SSHAuthenticationMethod {
        switch profile.authMethod {
        case .password:
            guard !secret.isEmpty else { throw SSHError.missingCredential }
            return .passwordBased(username: profile.username, password: secret)
        case .privateKey:
            return try privateKeyAuth()
        }
    }

    private func privateKeyAuth() throws -> SSHAuthenticationMethod {
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
        let passphrase = secret.isEmpty ? nil : Data(secret.utf8)
        let type = try SSHKeyDetection.detectPrivateKeyType(from: keyText)
        switch type {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: passphrase)
            return .ed25519(username: profile.username, privateKey: key)
        case .ecdsaP256:
            throw SSHError.unsupportedAlgorithm
        case .ecdsaP384:
            throw SSHError.unsupportedAlgorithm
        case .ecdsaP521:
            throw SSHError.unsupportedAlgorithm
        case .rsa:
            let key = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: passphrase)
            return .rsa(username: profile.username, privateKey: key)
        default:
            throw SSHError.unsupportedAlgorithm
        }
    }

    private func mapError(_ error: Error) -> SSHError {
        if let ssh = error as? SSHError { return ssh }
        if error is InvalidHostKey { return .unknownHostKey }
        let text = String(describing: error).lowercased()
        if text.contains("auth") { return .authenticationFailed }
        if text.contains("timeout") { return .timeout }
        if text.contains("closed") { return .connectionClosed }
        return .connectionFailed
    }
}

private struct AuthBox: @unchecked Sendable {
    let method: SSHAuthenticationMethod
    init(_ method: SSHAuthenticationMethod) { self.method = method }
}
