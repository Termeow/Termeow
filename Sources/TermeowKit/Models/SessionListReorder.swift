import Foundation

public enum SessionListPlacement: Equatable, Sendable {
    case favorites(before: UUID?)
    case ungrouped(before: UUID?)
    case group(String, before: UUID?)
}

public enum SessionListReorder {
    public static func moving(
        _ id: UUID,
        in profiles: [SessionProfile],
        to placement: SessionListPlacement
    ) -> [SessionProfile]? {
        guard let sourceIndex = profiles.firstIndex(where: { $0.id == id }) else { return nil }

        var profile = profiles[sourceIndex]
        switch placement {
        case .favorites:
            profile.isFavorite = true
        case .ungrouped:
            profile.isFavorite = false
            profile.groupName = ""
        case .group(let name, _):
            let groupName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupName.isEmpty else { return nil }
            profile.isFavorite = false
            profile.groupName = groupName
        }

        var result = profiles
        result.remove(at: sourceIndex)

        let before = beforeID(of: placement)
        let insertAt: Int
        if before == id {
            insertAt = min(sourceIndex, result.count)
        } else {
            insertAt = insertionIndex(before: before, matching: { belongs($0, to: placement) }, in: result)
        }
        result.insert(profile, at: insertAt)
        return result == profiles ? nil : result
    }

    private static func beforeID(of placement: SessionListPlacement) -> UUID? {
        switch placement {
        case .favorites(let before), .ungrouped(let before), .group(_, let before):
            before
        }
    }

    private static func belongs(_ profile: SessionProfile, to placement: SessionListPlacement) -> Bool {
        switch placement {
        case .favorites:
            profile.isFavorite
        case .ungrouped:
            !profile.isFavorite && profile.groupName.isEmpty
        case .group(let name, _):
            !profile.isFavorite
                && profile.groupName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func insertionIndex(
        before: UUID?,
        matching: (SessionProfile) -> Bool,
        in profiles: [SessionProfile]
    ) -> Int {
        if let before, let index = profiles.firstIndex(where: { $0.id == before }) {
            return index
        }
        if let last = profiles.lastIndex(where: matching) {
            return last + 1
        }
        return profiles.endIndex
    }
}
