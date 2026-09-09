import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import TermeowKit

@Test func forwardingRulesRoundTripAndLegacySessionsHaveNone() throws {
    let profile = SessionProfile(name: "test", host: "example.test", username: "tester", portForwards: [PortForwardRule()])
    let encoded = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(SessionProfile.self, from: encoded) == profile)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "portForwards")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(SessionProfile.self, from: legacy).portForwards.isEmpty)
}

@Test func forwardingValidationRejectsUnsafeOrConflictingRules() {
    var first = PortForwardRule()
    #expect(first.validationError == nil)
    #expect(!first.exposesNetwork)
    first.bindHost = "0.0.0.0"
    #expect(first.exposesNetwork)
    var second = PortForwardRule(kind: .dynamic)
    #expect(PortForwardRule.validationError(in: [first, second]) != nil)
    second.kind = .remote
    #expect(PortForwardRule.validationError(in: [first, second]) == nil)
    second.bindPort = 0
    #expect(second.validationError != nil)
    second.isEnabled = false
    #expect(PortForwardRule.validationError(in: [first, second]) == nil)
    first.bindHost = "localhost"
    #expect(first.validationError != nil)
    first.bindHost = "::1"
    first.destinationHost = "bad\nname"
    #expect(first.validationError != nil)
    #expect(PortForwardRule.validationError(in: [first, first]) != nil)
    #expect(PortForwardRule.validationError(in: (0..<33).map { _ in PortForwardRule(isEnabled: false) }) != nil)
}

@Test func forwardingCommandArgumentsDescribeEachMode() {
    let local = PortForwardRule(bindHost: "::1", bindPort: 8000, destinationHost: "2001:db8::1", destinationPort: 443)
    #expect(local.sshArguments == ["-L", "[::1]:8000:[2001:db8::1]:443"])
    #expect(PortForwardRule(kind: .dynamic, bindPort: 1080).sshArguments == ["-D", "127.0.0.1:1080"])
    #expect(PortForwardRule(kind: .remote).sshArguments == ["-R", "127.0.0.1:8080:127.0.0.1:80"])
}

@Test func socks5AcceptsEveryFragmentBoundaryAndPreservesPipelinedPayload() throws {
    let wire: [UInt8] = [5, 2, 2, 0, 5, 1, 0, 3, 11] + Array("example.com".utf8) + [1, 187] + Array("payload".utf8)
    for split in 0...wire.count {
        var parser = SOCKS5Handshake()
        var buffer = ByteBuffer(bytes: wire.prefix(split))
        var events: [SOCKS5Handshake.Message] = []
        while let event = try parser.next(from: &buffer) { events.append(event) }
        buffer.writeBytes(wire.dropFirst(split))
        while let event = try parser.next(from: &buffer) { events.append(event) }
        #expect(events == [.reply([5, 0]), .connect("example.com", 443)])
        #expect(String(buffer: buffer) == "payload")
    }
}

@Test func socks5SupportsIPv4AndIPv6() throws {
    let requests: [([UInt8], String)] = [
        ([1, 127, 0, 0, 1], "127.0.0.1"),
        ([4] + Array(repeating: 0, count: 15) + [1], "0:0:0:0:0:0:0:1")
    ]
    for (address, host) in requests {
        var parser = SOCKS5Handshake()
        var buffer = ByteBuffer(bytes: [5, 1, 0, 5, 1, 0] + address + [0, 22])
        #expect(try parser.next(from: &buffer) == .reply([5, 0]))
        #expect(try parser.next(from: &buffer) == .connect(host, 22))
    }
}

@Test func socks5RejectsUnsupportedAuthenticationCommandsAndMalformedRequests() throws {
    for greeting: [UInt8] in [[4, 1, 0], [5, 0], [5, 1, 2]] {
        var parser = SOCKS5Handshake()
        var buffer = ByteBuffer(bytes: greeting)
        #expect(throws: SOCKS5Failure.self) { try parser.next(from: &buffer) }
    }
    for request: [UInt8] in [[5, 2, 0, 1], [5, 3, 0, 1], [5, 1, 1, 1], [5, 1, 0, 8], [5, 1, 0, 3, 0], [5, 1, 0, 1, 127, 0, 0, 1, 0, 0]] {
        var parser = SOCKS5Handshake()
        var buffer = ByteBuffer(bytes: [5, 1, 0] + request)
        _ = try parser.next(from: &buffer)
        #expect(throws: SOCKS5Failure.self) { try parser.next(from: &buffer) }
    }
}

@Test func forwardingLifetimeRejectsLateChannelsAfterStop() throws {
    let lifetime = ForwardingLifetime()
    let channel = EmbeddedChannel()
    #expect(lifetime.own(channel))
    lifetime.close()
    channel.embeddedEventLoop.run()
    try channel.closeFuture.wait()
    let late = EmbeddedChannel()
    #expect(!lifetime.own(late))
    late.embeddedEventLoop.run()
    try late.closeFuture.wait()
}
