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
