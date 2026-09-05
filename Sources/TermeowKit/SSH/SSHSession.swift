import Foundation

public protocol SSHSession: Sendable {
    var state: SSHConnectionState { get }
    var output: AsyncStream<Data> { get }
    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
}

public typealias HostKeyPromptHandler = @Sendable (HostKeyCheck) async -> HostKeyDecision
