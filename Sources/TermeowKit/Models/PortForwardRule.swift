import Foundation
import NIOCore

public enum PortForwardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, remote, dynamic
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .local: "Local (-L)"
        case .remote: "Remote (-R)"
        case .dynamic: "Dynamic SOCKS5 (-D)"
        }
    }
}

public struct PortForwardRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: PortForwardKind
    public var bindHost: String
    public var bindPort: Int
    public var destinationHost: String
    public var destinationPort: Int
    public var isEnabled: Bool

    public init(id: UUID = UUID(), kind: PortForwardKind = .local, bindHost: String = "127.0.0.1", bindPort: Int = 8080,
                destinationHost: String = "127.0.0.1", destinationPort: Int = 80, isEnabled: Bool = true) {
        self.id = id; self.kind = kind; self.bindHost = bindHost; self.bindPort = bindPort
        self.destinationHost = destinationHost; self.destinationPort = destinationPort; self.isEnabled = isEnabled
    }

    public var exposesNetwork: Bool { bindHost != "127.0.0.1" && bindHost != "::1" }
    public var summary: String {
        let listener = "\(Self.address(bindHost)):\(bindPort)"
        return kind == .dynamic ? "\(listener) → SOCKS5" : "\(listener) → \(Self.address(destinationHost)):\(destinationPort)"
    }
    public var validationError: String? {
        guard SessionProfile.validPortRange.contains(bindPort) else { return "Listen port must be between 1 and 65535." }
        guard (try? SocketAddress(ipAddress: bindHost, port: bindPort)) != nil else {
            return "Listen address must be an IPv4 or IPv6 address, such as 127.0.0.1 or ::1."
        }
        if kind != .dynamic {
            guard Self.validDestination(destinationHost), SessionProfile.validPortRange.contains(destinationPort) else {
                return "Enter a destination hostname or IP address and a port between 1 and 65535."
            }
        }
        return nil
    }

    public static func validationError(in rules: [Self]) -> String? {
        guard rules.count <= 32 else { return "A session can contain at most 32 forwarding rules." }
        guard Set(rules.map(\.id)).count == rules.count else { return "Forwarding rules must have unique IDs." }
        let enabled = rules.filter(\.isEnabled)
        for (index, rule) in enabled.enumerated() {
            if let error = rule.validationError { return error }
            for previous in enabled.prefix(index) where previous.bindPort == rule.bindPort {
                let sameSide = (previous.kind == .remote) == (rule.kind == .remote)
                let sameFamily = previous.bindHost.contains(":") == rule.bindHost.contains(":")
                let wildcard = [previous.bindHost, rule.bindHost].contains("0.0.0.0") || [previous.bindHost, rule.bindHost].contains("::")
                if sameSide && sameFamily && (previous.bindHost == rule.bindHost || wildcard) {
                    return "Enabled forwarding rules cannot share the same listening address and port."
                }
            }
        }
        return nil
    }

    public var sshArguments: [String] {
        let option = kind == .local ? "-L" : kind == .remote ? "-R" : "-D"
        let listener = "\(Self.address(bindHost)):\(bindPort)"
        return [option, kind == .dynamic ? listener : "\(listener):\(Self.address(destinationHost)):\(destinationPort)"]
    }

    static func validDestination(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && !host.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
        } && !host.contains("/") && !host.contains("[") && !host.contains("]")
    }
    private static func address(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }
}

public enum PortForwardState: Equatable, Sendable {
    case stopped, starting, listening, stopping, failed(String)
    public var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .listening: "Listening"
        case .stopping: "Stopping"
        case .failed(let message): message
        }
    }
}

public struct PortForwardStatus: Identifiable, Equatable, Sendable {
    public var id: UUID { rule.id }
    public let rule: PortForwardRule
    public var state: PortForwardState
    public var connections: Int = 0
    public var lastError: String?

    public init(rule: PortForwardRule, state: PortForwardState, connections: Int = 0, lastError: String? = nil) {
        self.rule = rule; self.state = state; self.connections = connections; self.lastError = lastError
    }
}
