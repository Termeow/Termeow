import Foundation

public enum TabReorder {
    public static func targetID<ID: Hashable>(
        sourceIndex: Int,
        sourceFrame: CGRect,
        pointerX: CGFloat,
        orderedIDs: [ID],
        frames: [ID: CGRect],
        hysteresis: CGFloat = 4
    ) -> ID? {
        guard orderedIDs.indices.contains(sourceIndex) else { return nil }

        if pointerX < sourceFrame.midX, sourceIndex > orderedIDs.startIndex {
            let adjacentID = orderedIDs[sourceIndex - 1]
            guard let adjacentFrame = frames[adjacentID] else { return nil }
            let activationBoundary = (sourceFrame.midX + adjacentFrame.midX) / 2 - hysteresis
            guard pointerX <= activationBoundary else { return nil }
            return closestID(to: pointerX, among: orderedIDs[..<sourceIndex], frames: frames)
        }

        if sourceIndex + 1 < orderedIDs.endIndex {
            let adjacentID = orderedIDs[sourceIndex + 1]
            guard let adjacentFrame = frames[adjacentID] else { return nil }
            let activationBoundary = (sourceFrame.midX + adjacentFrame.midX) / 2 + hysteresis
            guard pointerX >= activationBoundary else { return nil }
            return closestID(to: pointerX, among: orderedIDs[(sourceIndex + 1)...], frames: frames)
        }

        return nil
    }

    /// Same placement as removing `sourceID` and inserting it at `targetID`'s original index.
    public static func previewIDs<ID: Equatable>(
        _ ids: [ID],
        moving sourceID: ID,
        over targetID: ID?
    ) -> [ID] {
        guard let sourceIndex = ids.firstIndex(of: sourceID) else { return ids }
        var preview = ids
        let item = preview.remove(at: sourceIndex)
        let insertAt: Int
        if let targetID, let dest = ids.firstIndex(of: targetID), dest != sourceIndex {
            insertAt = min(dest, preview.count)
        } else {
            insertAt = min(sourceIndex, preview.count)
        }
        preview.insert(item, at: insertAt)
        return preview
    }

    private static func closestID<ID: Hashable>(
        to pointerX: CGFloat,
        among ids: some Sequence<ID>,
        frames: [ID: CGRect]
    ) -> ID? {
        ids.compactMap { id in
            frames[id].map { (id: id, distance: abs($0.midX - pointerX)) }
        }
        .min(by: { $0.distance < $1.distance })?
        .id
    }
}
