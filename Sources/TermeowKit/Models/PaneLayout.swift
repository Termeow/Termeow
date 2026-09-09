import Foundation

public enum PaneSplitAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case leaf(UUID)
    case split(axis: PaneSplitAxis, first: PaneLayout, second: PaneLayout)

    public var paneIDs: [UUID] {
        switch self {
        case .leaf(let id):
            [id]
        case .split(_, let first, let second):
            first.paneIDs + second.paneIDs
        }
    }

    public func contains(_ paneID: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            id == paneID
        case .split(_, let first, let second):
            first.contains(paneID) || second.contains(paneID)
        }
    }

    public func splitting(
        paneID: UUID,
        newPaneID: UUID,
        axis: PaneSplitAxis
    ) -> PaneLayout? {
        switch self {
        case .leaf(let id):
            guard id == paneID else { return nil }
            return .split(axis: axis, first: .leaf(id), second: .leaf(newPaneID))
        case .split(let currentAxis, let first, let second):
            if let updatedFirst = first.splitting(paneID: paneID, newPaneID: newPaneID, axis: axis) {
                return .split(axis: currentAxis, first: updatedFirst, second: second)
            }
            if let updatedSecond = second.splitting(paneID: paneID, newPaneID: newPaneID, axis: axis) {
                return .split(axis: currentAxis, first: first, second: updatedSecond)
            }
            return nil
        }
    }

    public func removing(_ paneID: UUID) -> PaneLayout? {
        switch self {
        case .leaf(let id):
            return id == paneID ? nil : self
        case .split(let axis, let first, let second):
            let updatedFirst = first.removing(paneID)
            let updatedSecond = second.removing(paneID)
            switch (updatedFirst, updatedSecond) {
            case (nil, nil):
                return nil
            case (nil, let remaining?):
                return remaining
            case (let remaining?, nil):
                return remaining
            case (let first?, let second?):
                return .split(axis: axis, first: first, second: second)
            }
        }
    }

    public func retaining(_ paneIDs: Set<UUID>) -> PaneLayout? {
        switch self {
        case .leaf(let id):
            return paneIDs.contains(id) ? self : nil
        case .split(let axis, let first, let second):
            let retainedFirst = first.retaining(paneIDs)
            let retainedSecond = second.retaining(paneIDs)
            switch (retainedFirst, retainedSecond) {
            case (nil, nil):
                return nil
            case (nil, let remaining?):
                return remaining
            case (let remaining?, nil):
                return remaining
            case (let first?, let second?):
                return .split(axis: axis, first: first, second: second)
            }
        }
    }

    public func mappingPaneIDs(_ transform: (UUID) -> UUID) -> PaneLayout {
        switch self {
        case .leaf(let id):
            .leaf(transform(id))
        case .split(let axis, let first, let second):
            .split(
                axis: axis,
                first: first.mappingPaneIDs(transform),
                second: second.mappingPaneIDs(transform)
            )
        }
    }
}
