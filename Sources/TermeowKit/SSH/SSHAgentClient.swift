import Crypto
import Darwin
import Foundation

public enum SSHAgentError: String, Error, Equatable, Sendable, LocalizedError {
    case unavailable, invalidSocket, untrustedPeer, invalidResponse, refused, timedOut, cancelled, missingIdentity, unsupportedKey, invalidSignature

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The SSH agent is unavailable. Start your agent and check its socket path or SSH_AUTH_SOCK."
        case .invalidSocket: "Enter an absolute Unix socket path (or ~/...). Leave it empty to use SSH_AUTH_SOCK."
        case .untrustedPeer: "The SSH agent must run as the current macOS user."
        case .invalidResponse: "The SSH agent returned an invalid or oversized response."
        case .refused: "The SSH agent refused the request. Unlock the agent, check that the key is loaded, and approve the request."
        case .timedOut: "The SSH agent request timed out. Approve it in your agent, then reconnect."
        case .cancelled: "The SSH agent request was cancelled."
        case .missingIdentity: "Select an SSH agent key for this session."
        case .unsupportedKey: "This agent key is not supported. Choose Ed25519, RSA (2048-8192 bits), or ECDSA P-256/P-384/P-521."
        case .invalidSignature: "The SSH agent returned an invalid signature or did not honor the requested signature algorithm."
        }
    }
}

public struct SSHAgentConfiguration: Codable, Equatable, Sendable {
    public var socketPath: String
    public var publicKey: Data?
    public var rsaSHA256: Bool

    public init(socketPath: String = "", publicKey: Data? = nil, rsaSHA256: Bool = false) {
        self.socketPath = socketPath; self.publicKey = publicKey; self.rsaSHA256 = rsaSHA256
    }

    public var identity: SSHAgentIdentity? { publicKey.flatMap { try? SSHAgentIdentity(blob: $0, comment: "") } }
    public var validationError: String? {
        guard let identity else { return SSHAgentError.missingIdentity.localizedDescription }
        guard identity.isSupported else { return SSHAgentError.unsupportedKey.localizedDescription }
        let path = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || Self.validPath((path as NSString).expandingTildeInPath) else {
            return SSHAgentError.invalidSocket.localizedDescription
        }
        return nil
    }

    public func resolvedSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let specified = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = specified.isEmpty ? (environment["SSH_AUTH_SOCK"] ?? "") : specified
        guard !path.isEmpty else { throw SSHAgentError.unavailable }
        let expanded = (path as NSString).expandingTildeInPath
        guard Self.validPath(expanded) else { throw SSHAgentError.invalidSocket }
        return expanded
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count < 104 && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct SSHAgentIdentity: Identifiable, Equatable, Sendable {
    public let blob: Data
    public let comment: String
    public let algorithm: String
    public var id: String { "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    public private(set) var isSupported = false
    public var authorizedKey: String { "\(algorithm) \(blob.base64EncodedString())" }

    public init(blob: Data, comment: String) throws {
        guard blob.count <= 16_384 else { throw SSHAgentError.invalidResponse }
        var wire = AgentWire(blob)
        let algorithm = try wire.string()
        guard !algorithm.isEmpty, algorithm.utf8.count <= 128 else { throw SSHAgentError.invalidResponse }
        self.blob = blob
        self.algorithm = algorithm
        self.comment = String(comment.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(256).map(String.init).joined())
        if SSHAgentKeyMaterial.supportedAlgorithms.contains(algorithm) {
            do { _ = try SSHAgentKeyMaterial(identity: self); isSupported = true }
            catch SSHAgentError.unsupportedKey { isSupported = false }
        }
    }
}

public enum SSHAgentClient {
    /// Lists public metadata only. This client never adds/removes keys, unlocks an agent, or forwards its socket.
    public static func identities(socketPath: String = "") async throws -> [SSHAgentIdentity] {
        let path = try SSHAgentConfiguration(socketPath: socketPath).resolvedSocketPath()
        let access = SSHAgentAccess()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try decodeIdentities(access.request(path: path, payload: Data([11]), timeout: 10))
            }.value
        } onCancel: { access.cancel() }
    }

    static func decodeIdentities(_ data: Data) throws -> [SSHAgentIdentity] {
        var wire = AgentWire(data)
        guard try wire.byte() == 12 else { throw data == Data([5]) ? SSHAgentError.refused : .invalidResponse }
        let count = try wire.uint32()
        guard count <= 256 else { throw SSHAgentError.invalidResponse }
        var identities: [SSHAgentIdentity] = []
        var seen: Set<Data> = []
        for _ in 0..<count {
            let blob = try wire.bytes(limit: 16_384)
            let comment = try wire.string(limit: 4096)
            let key = try SSHAgentIdentity(blob: blob, comment: comment)
            if seen.insert(blob).inserted { identities.append(key) }
        }
        guard wire.isEmpty else { throw SSHAgentError.invalidResponse }
        return identities
    }
}

/// A cancellation handle independent of the SSH event loop. Shutdown wakes a pending socket read without fd-reuse races.
final class SSHAgentAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var sockets: Set<Int32> = []
    private var failure: SSHAgentError?
    var lastError: SSHAgentError? { lock.lock(); defer { lock.unlock() }; return failure }

    func record(_ error: SSHAgentError) {
        lock.lock(); defer { lock.unlock() }
        failure = cancelled ? .cancelled : error
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        for fd in sockets { _ = Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw SSHAgentError.cancelled }
    }

    private func register(_ fd: Int32) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw SSHAgentError.cancelled }
        sockets.insert(fd)
    }

    private func release(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        sockets.remove(fd)
        _ = Darwin.close(fd)
    }

    func request(path: String, payload: Data, timeout: TimeInterval) throws -> Data {
        do { return try exchange(path: path, payload: payload, timeout: timeout) }
        catch {
            let mapped = (error as? SSHAgentError) ?? .unavailable
            lock.lock(); failure = cancelled ? .cancelled : mapped; let result = failure!; lock.unlock()
            throw result
        }
    }

    private func exchange(path: String, payload: Data, timeout: TimeInterval) throws -> Data {
        try check()
        guard !payload.isEmpty, payload.count <= 1_048_576, timeout > 0 else { throw SSHAgentError.invalidResponse }
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard path.hasPrefix("/"), !pathBytes.contains(0), pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SSHAgentError.invalidSocket
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: pathBytes + [0]) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHAgentError.unavailable }
        do { try register(fd) } catch { _ = Darwin.close(fd); throw error }
        defer { release(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw SSHAgentError.unavailable }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SSHAgentError.unavailable
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(min(timeout, 120) * 1000)))
        func wait(_ events: Int16) throws {
            while true {
                try check()
                guard ContinuousClock.now < deadline else { throw SSHAgentError.timedOut }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = Darwin.poll(&descriptor, 1, 50)
                if result > 0 {
                    try check()
                    if descriptor.revents & events != 0 { return }
                    throw SSHAgentError.unavailable
                }
                if result < 0 && errno != EINTR { throw SSHAgentError.unavailable }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw SSHAgentError.unavailable }
            try wait(Int16(POLLOUT))
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw SSHAgentError.unavailable }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw SSHAgentError.untrustedPeer }
        var framed = AgentWire()
        framed.append(UInt32(payload.count)); framed.data.append(payload)
        var sent = 0
        while sent < framed.data.count {
            try wait(Int16(POLLOUT))
            let count = framed.data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), $0.count - sent) }
            if count > 0 { sent += count }
            else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { throw SSHAgentError.unavailable }
        }
        func read(_ length: Int) throws -> Data {
            var data = Data(count: length)
            var received = 0
            while received < length {
                try wait(Int16(POLLIN))
                let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: received), length - received) }
                if count > 0 { received += count }
                else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { throw SSHAgentError.unavailable }
            }
            return data
        }
        var header = AgentWire(try read(4))
        let length = try header.uint32()
        guard length > 0, length <= 1_048_576 else { throw SSHAgentError.invalidResponse }
        return try read(Int(length))
    }
}

struct AgentWire {
    var data: Data
    private var index = 0
    init(_ data: Data = Data()) { self.data = Data(data) }
    var isEmpty: Bool { index == data.count }
    mutating func byte() throws -> UInt8 {
        guard index < data.count else { throw SSHAgentError.invalidResponse }
        defer { index += 1 }; return data[index]
    }
    mutating func uint32() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 { result = (result << 8) | UInt32(try byte()) }
        return result
    }
    mutating func bytes(limit: Int = 1_048_576) throws -> Data {
        let length = Int(try uint32())
        guard length <= limit, length <= data.count - index else { throw SSHAgentError.invalidResponse }
        defer { index += length }; return Data(data[index..<(index + length)])
    }
    mutating func string(limit: Int = 128) throws -> String {
        guard let value = String(data: try bytes(limit: limit), encoding: .utf8) else { throw SSHAgentError.invalidResponse }
        return value
    }
    mutating func append(_ value: UInt32) {
        data.append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    mutating func append(_ bytes: Data) { append(UInt32(bytes.count)); data.append(bytes) }
    mutating func append(_ text: String) { append(Data(text.utf8)) }
}
