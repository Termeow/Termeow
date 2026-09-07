import Foundation

public enum SessionListPlacement: Equatable, Sendable {
    case favorites(over: UUID?)
    case ungrouped(over: UUID?)
    case group(String, over: UUID?)
}

public enum SessionListReorder {
    public static func moving(
        _ id: UUID,
        in profiles: [SessionProfile],
        to placement: SessionListPlacement
    ) -> [SessionProfile]? {
        guard let sourceIndex = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let alreadyInDest = belongs(profiles[sourceIndex], to: placement)

        var updated = profiles
        switch placement {
        case .favorites:
            updated[sourceIndex].isFavorite = true
        case .ungrouped:
            updated[sourceIndex].isFavorite = false
            updated[sourceIndex].groupName = ""
        case .group(let name, _):
            let groupName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupName.isEmpty else { return nil }
            updated[sourceIndex].isFavorite = false
            updated[sourceIndex].groupName = groupName
        }

        let over = overID(of: placement)
        let members = updated.filter { belongs($0, to: placement) }.map(\.id)
        let sectionIDs = alreadyInDest ? members : members.filter { $0 != id } + [id]
        let ordered = TabReorder.previewIDs(sectionIDs, moving: id, over: over)
        guard let source = updated.first(where: { $0.id == id }) else { return nil }
        var result = updated.filter { $0.id != id }
        result.insert(source, at: insertionIndex(for: id, in: ordered, among: result))
        return result == profiles ? nil : result
    }

    /// Writes `orderedIDs` back into `profiles`, keeping every other session in place.
    public static func applyingSectionOrder(
        _ orderedIDs: [UUID],
        in profiles: [SessionProfile]
    ) -> [SessionProfile]? {
        let idSet = Set(orderedIDs)
        guard orderedIDs.count == idSet.count,
              orderedIDs.allSatisfy({ id in profiles.contains { $0.id == id } }) else {
            return nil
        }
        let lookup = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var emitted = false
        var result: [SessionProfile] = []
        result.reserveCapacity(profiles.count)
        for profile in profiles {
            if idSet.contains(profile.id) {
                if !emitted {
                    result.append(contentsOf: orderedIDs.compactMap { lookup[$0] })
                    emitted = true
                }
            } else {
                result.append(profile)
            }
        }
        return result == profiles ? nil : result
    }

    private static func overID(of placement: SessionListPlacement) -> UUID? {
        switch placement {
        case .favorites(let over), .ungrouped(let over), .group(_, let over):
            over
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

    private static func insertionIndex(for id: UUID, in ordered: [UUID], among result: [SessionProfile]) -> Int {
        guard let position = ordered.firstIndex(of: id) else { return result.endIndex }
        if position + 1 < ordered.count {
            let next = ordered[position + 1]
            return result.firstIndex(where: { $0.id == next }) ?? result.endIndex
        }
        if let previous = ordered[..<position].last,
           let index = result.firstIndex(where: { $0.id == previous }) {
            return index + 1
        }
        return result.endIndex
    }
}
