import Foundation
import Testing
@testable import TermeowKit

/// Opt-in tests only: use an explicitly authorized disposable SSH server with TCP forwarding enabled.
/// The forwarded destination is loopback as seen by that server, not the machine running these tests.
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["TERMEOW_SSH_TEST_HOST"] != nil))
struct ProxyJumpLiveTests {
    private func route(jumps: Int) throws -> [SSHConnectionHop] {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(env["TERMEOW_SSH_TEST_HOST"])
        let username = try #require(env["TERMEOW_SSH_TEST_USER"])
        let secret = try #require(env["TERMEOW_SSH_TEST_PASSWORD"])
        let port = Int(env["TERMEOW_SSH_TEST_PORT"] ?? "22") ?? 22
        var hops: [SSHConnectionHop] = []
        for index in 0...jumps {
            let profile = SessionProfile(
                name: "Test hop \(index)", host: index == 0 ? host : "127.0.0.1", port: port,
                username: username, startupCommand: "printf 'TERMEOW_PROXY_JUMP_READY\\n'",
                keepAliveSeconds: 0, timeoutSeconds: 10, jumpHostID: hops.last?.profile.id
            )
            hops.append(SSHConnectionHop(profile: profile, secret: secret))
        }
        return hops
    }

    @Test(arguments: [0, 1, 2]) func terminalAndSFTPThroughRoute(jumps: Int) async throws {
        let route = try route(jumps: jumps)
        let target = try #require(route.last)
        let checks = RouteKeyChecks()
        let session = CitadelSSHSession(
            profile: target.profile, secret: target.secret, hostKeyStore: isolatedRouteHostKeyStore(),
            jumpHosts: Array(route.dropLast())
        ) { check in await checks.record(check); return .connectOnce }
        do {
            try await session.connect()
            #expect(session.state == .connected)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var text = ""
                    for await data in session.output {
                        text += String(decoding: data, as: UTF8.self)
                        if text.contains("TERMEOW_PROXY_JUMP_READY") { return }
                    }
                    throw SSHError.connectionClosed
                }
                group.addTask { try await Task.sleep(for: .seconds(10)); throw SSHError.timeout }
                defer { group.cancelAll() }
                try await group.next()
            }
            #expect(await checks.count == jumps + 1)
            await session.disconnect()
            #expect(session.state == .disconnected)
        } catch { await session.disconnect(); throw error }

        let sftp = CitadelSFTPService(
            profile: target.profile, secret: target.secret, hostKeyStore: isolatedRouteHostKeyStore(),
            jumpHosts: Array(route.dropLast())
        ) { _ in .connectOnce }
        do {
            let home = try await sftp.connect()
            #expect(home.hasPrefix("/"))
            let listing = try await sftp.listDirectory(at: home)
            #expect(listing.path == home)
            await sftp.disconnect()
            await #expect(throws: SFTPServiceError.notConnected) { _ = try await sftp.listDirectory(at: home) }
        } catch { await sftp.disconnect(); throw error }
    }

    @Test func rejectsIntermediateHostKeyWithoutReachingTarget() async throws {
        let route = try route(jumps: 2)
        let target = try #require(route.last)
        let checks = RouteKeyChecks()
        await #expect(throws: SSHError.jumpHostFailed(route[1].profile.displayName, .hostKeyRejected)) {
            _ = try await CitadelConnectionFactory.connect(
                profile: target.profile, secret: target.secret, hostKeyStore: isolatedRouteHostKeyStore(),
                jumpHosts: Array(route.dropLast())
            ) { check in
                await checks.record(check)
                return await checks.count == 2 ? .cancel : .connectOnce
            }
        }
        #expect(await checks.count == 2)
    }

    @Test func rejectsIncorrectIntermediatePassword() async throws {
        let route = try route(jumps: 2)
        let target = try #require(route.last)
        let hops = [route[0], SSHConnectionHop(profile: route[1].profile, secret: UUID().uuidString)]
        await #expect(throws: SSHError.jumpHostFailed(route[1].profile.displayName, .authenticationFailed)) {
            _ = try await CitadelConnectionFactory.connect(
                profile: target.profile, secret: target.secret, hostKeyStore: isolatedRouteHostKeyStore(), jumpHosts: hops
            ) { _ in .connectOnce }
        }
    }

    @Test func cancellationClosesPendingJumpAndPrompt() async throws {
        let route = try route(jumps: 2)
        let target = try #require(route.last)
        let checks = RouteKeyChecks()
        let waiting = AsyncStream<Void>.makeStream()
        let promptCancelled = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { waiting.continuation.finish(); promptCancelled.continuation.finish() }
            return try await CitadelConnectionFactory.connect(
                profile: target.profile, secret: target.secret, hostKeyStore: isolatedRouteHostKeyStore(),
                jumpHosts: Array(route.dropLast())
            ) { check in
                await checks.record(check)
                if await checks.count == 2 {
                    waiting.continuation.yield(())
                    do { try await Task.sleep(for: .seconds(20)) }
                    catch { promptCancelled.continuation.yield(()) }
                    return .cancel
                }
                return .connectOnce
            }
        }
        var started = waiting.stream.makeAsyncIterator()
        _ = await started.next()
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        var cancelled = promptCancelled.stream.makeAsyncIterator()
        _ = await cancelled.next()
        #expect(start.duration(to: .now) < .seconds(3))
        #expect(await checks.count == 2)
    }

    @Test func disconnectCancelsSFTPWhileJumpIsPending() async throws {
        let route = try route(jumps: 1)
        let target = try #require(route.last)
        let waiting = AsyncStream<Void>.makeStream()
        let sftp = CitadelSFTPService(
            profile: target.profile, secret: target.secret, hostKeyStore: isolatedRouteHostKeyStore(),
            jumpHosts: Array(route.dropLast())
        ) { _ in
            waiting.continuation.yield(())
            try? await Task.sleep(for: .seconds(20))
            return .cancel
        }
        let task = Task {
            defer { waiting.continuation.finish() }
            return try await sftp.connect()
        }
        var iterator = waiting.stream.makeAsyncIterator()
        _ = await iterator.next()
        await sftp.disconnect()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        await #expect(throws: SFTPServiceError.notConnected) { _ = try await sftp.listDirectory(at: "/") }
    }

    @Test func disconnectCancelsTerminalWhileJumpIsPending() async throws {
        let route = try route(jumps: 1)
        let target = try #require(route.last)
        let waiting = AsyncStream<Void>.makeStream()
        let session = CitadelSSHSession(
            profile: target.profile, secret: target.secret, hostKeyStore: isolatedRouteHostKeyStore(),
            jumpHosts: Array(route.dropLast())
        ) { _ in
            waiting.continuation.yield(())
            try? await Task.sleep(for: .seconds(20))
            return .cancel
        }
        let task = Task {
            defer { waiting.continuation.finish() }
            try await session.connect()
        }
        var iterator = waiting.stream.makeAsyncIterator()
        _ = await iterator.next()
        await session.disconnect()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(session.state == .disconnected)
    }

    @Test func pendingJumpTimesOutAndCancelsPrompt() async throws {
        let route = try route(jumps: 1)
        let target = try #require(route.last)
        var profile = target.profile
        profile.timeoutSeconds = 1
        let checks = RouteKeyChecks()
        let start = ContinuousClock.now
        await #expect(throws: SSHError.timeout) {
            _ = try await CitadelConnectionFactory.connect(
                profile: profile, secret: target.secret, hostKeyStore: isolatedRouteHostKeyStore(),
                jumpHosts: Array(route.dropLast())
            ) { check in
                await checks.record(check)
                if await checks.count == 2 {
                    try? await Task.sleep(for: .seconds(20))
                    return .cancel
                }
                return .connectOnce
            }
        }
        #expect(start.duration(to: .now) < .seconds(4))
        #expect(await checks.count == 2)
    }
}

private actor RouteKeyChecks {
    private(set) var count = 0
    func record(_ check: HostKeyCheck) { count += 1 }
}
