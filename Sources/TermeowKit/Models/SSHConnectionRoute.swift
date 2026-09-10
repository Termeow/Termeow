import Foundation

public enum SSHRouteError: Error, Equatable, Sendable, LocalizedError {
    case missingJumpHost
    case cycle
    case tooManyHops
    case invalidProfile

    public var errorDescription: String? {
        switch self {
        case .missingJumpHost: "A saved jump host is missing. Choose another jump host or explicitly select Direct Connection."
        case .cycle: "The jump-host route contains a cycle. A session cannot depend on itself."
        case .tooManyHops: "A route can contain at most eight jump hosts."
        case .invalidProfile: "A session in the route has an invalid host, username, port, timeout, or agent identity."
        }
    }
}

public enum SSHConnectionRoute {
    public static let maximumJumpHosts = 8

    /// Resolve outermost jump first and destination last. Never fall back to a direct connection.
    public static func resolve(destination: SessionProfile, profiles: [SessionProfile]) throws -> [SessionProfile] {
        var route = [destination]
        var visited: Set<UUID> = [destination.id]
        var current = destination
        while let id = current.jumpHostID {
            guard visited.insert(id).inserted else { throw SSHRouteError.cycle }
            guard route.count <= maximumJumpHosts else { throw SSHRouteError.tooManyHops }
            guard let next = profiles.first(where: { $0.id == id }) else { throw SSHRouteError.missingJumpHost }
            route.append(next)
            current = next
        }
        guard route.allSatisfy(\.isValidForSaving) else { throw SSHRouteError.invalidProfile }
        return route.reversed()
    }

    public static func validatePreparedRoute(jumpHosts: [SSHConnectionHop], destination: SessionProfile) throws {
        let profiles = jumpHosts.map(\.profile) + [destination]
        let resolved = try resolve(destination: destination, profiles: profiles)
        guard resolved.map(\.id) == profiles.map(\.id) else { throw SSHRouteError.cycle }
    }
}

/// Ephemeral credentials for one hop. Never serialized into the session library.
public struct SSHConnectionHop: Sendable {
    public let profile: SessionProfile
    public let secret: String
    public init(profile: SessionProfile, secret: String) { self.profile = profile; self.secret = secret }
}
