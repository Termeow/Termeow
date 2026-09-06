import Foundation

public struct SessionLibrary: Codable, Equatable, Sendable {
    public var profiles: [SessionProfile]
    public var groups: [String]

    public init(profiles: [SessionProfile] = [], groups: [String] = []) {
        self.profiles = profiles
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey {
        case profiles
        case groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([SessionProfile].self, forKey: .profiles) ?? []
        groups = try container.decodeIfPresent([String].self, forKey: .groups) ?? []
    }
}
