import Foundation
import CoreGraphics

public enum SplitDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var axis: PaneSplitAxis { self == .left || self == .right ? .vertical : .horizontal }
    public var before: Bool { self == .left || self == .up }
}

public struct TerminalTabGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var tabIDs: [UUID]
    public var selectedTabID: UUID?

    public init(id: UUID = UUID(), tabIDs: [UUID] = [], selectedTabID: UUID? = nil) {
        self.id = id
        self.tabIDs = tabIDs
        self.selectedTabID = selectedTabID ?? tabIDs.first
    }
}

/// Group IDs are layout leaves. Moving a tab only changes membership, never its connection.
public struct TabGroupWorkspace: Codable, Equatable, Sendable {
    public var groups: [TerminalTabGroup]
    public var layout: PaneLayout
    public var activeGroupID: UUID
    public var ratios: [String: Double] = [:]
    public var maximizedGroupID: UUID?

    public init(tabIDs: [UUID] = []) {
        let group = TerminalTabGroup(tabIDs: tabIDs)
        groups = [group]
        layout = .leaf(group.id)
        activeGroupID = group.id
    }

    public var activeGroup: TerminalTabGroup? { groups.first { $0.id == activeGroupID } }

    public mutating func reconcile(tabIDs: [UUID], selectedTabID: UUID?) {
        if groups.isEmpty { self = TabGroupWorkspace(tabIDs: tabIDs) }
        let groupIDs = groups.map(\.id)
        if Set(groupIDs).count != groupIDs.count || Set(layout.paneIDs) != Set(groupIDs)
            || layout.paneIDs.count != groupIDs.count {
            self = TabGroupWorkspace(tabIDs: tabIDs)
        }
        ratios = ratios.mapValues { $0.isFinite ? min(0.9, max(0.1, $0)) : 0.5 }
        if let maximizedGroupID, !groups.contains(where: { $0.id == maximizedGroupID }) {
            self.maximizedGroupID = nil
        }
        let valid = Set(tabIDs)
        var seen = Set<UUID>()
        for index in groups.indices {
            groups[index].tabIDs = groups[index].tabIDs.filter { valid.contains($0) && seen.insert($0).inserted }
            if !groups[index].tabIDs.contains(groups[index].selectedTabID ?? UUID()) {
                groups[index].selectedTabID = groups[index].tabIDs.first
            }
        }
        if !groups.contains(where: { $0.id == activeGroupID }) { activeGroupID = groups[0].id }
        let index = groups.firstIndex { $0.id == activeGroupID }!
        groups[index].tabIDs += tabIDs.filter { !seen.contains($0) }
        if groups[index].selectedTabID == nil { groups[index].selectedTabID = groups[index].tabIDs.first }
        if let selectedTabID, let selectedIndex = groups.firstIndex(where: { $0.tabIDs.contains(selectedTabID) }) {
            groups[selectedIndex].selectedTabID = selectedTabID
            activeGroupID = groups[selectedIndex].id
        }
    }

    public mutating func activate(_ groupID: UUID) {
        guard groups.contains(where: { $0.id == groupID }) else { return }
        activeGroupID = groupID
        if maximizedGroupID != nil { maximizedGroupID = groupID }
    }

    @discardableResult
    public mutating func split(groupID: UUID, direction: SplitDirection, moving tabID: UUID? = nil) -> UUID? {
        guard layout.contains(groupID), groups.count < 16 else { return nil }
        let newGroup = TerminalTabGroup()
        guard let divided = layout.splitting(paneID: groupID, newPaneID: newGroup.id, axis: direction.axis) else { return nil }
        layout = direction.before ? divided.mappingPaneIDs { $0 == groupID ? newGroup.id : ($0 == newGroup.id ? groupID : $0) } : divided
        groups.append(newGroup)
        maximizedGroupID = nil
        if let tabID { move(tabID, to: newGroup.id) }
        activate(newGroup.id)
        return newGroup.id
    }

    public mutating func move(_ tabID: UUID, to groupID: UUID, before targetID: UUID? = nil) {
        guard let source = groups.firstIndex(where: { $0.tabIDs.contains(tabID) }),
              groups.contains(where: { $0.id == groupID }), targetID != tabID else { return }
        let oldGroupID = groups[source].id
        groups[source].tabIDs.removeAll { $0 == tabID }
        if groups[source].selectedTabID == tabID { groups[source].selectedTabID = groups[source].tabIDs.first }
        let destination = groups.firstIndex { $0.id == groupID }!
        let index = targetID.flatMap { groups[destination].tabIDs.firstIndex(of: $0) } ?? groups[destination].tabIDs.count
        groups[destination].tabIDs.insert(tabID, at: index)
        groups[destination].selectedTabID = tabID
        activate(groupID)
        if oldGroupID != groupID, groups.first(where: { $0.id == oldGroupID })?.tabIDs.isEmpty == true {
            removeGroup(oldGroupID)
        }
    }

    /// An outer-edge drop splits the entire workspace, not just the nearest leaf.
    @discardableResult
    public mutating func splitWorkspace(direction: SplitDirection, moving tabID: UUID) -> UUID? {
        guard groups.count < 16, groups.contains(where: { $0.tabIDs.contains(tabID) }),
              groups.reduce(0, { $0 + $1.tabIDs.count }) > 1 else { return nil }
        let newGroup = TerminalTabGroup()
        let existingPrefix = direction.before ? "r1" : "r0"
        ratios = Dictionary(uniqueKeysWithValues: ratios.map { (existingPrefix + $0.key.dropFirst(), $0.value) })
        layout = .split(axis: direction.axis,
                        first: direction.before ? .leaf(newGroup.id) : layout,
                        second: direction.before ? layout : .leaf(newGroup.id))
        groups.append(newGroup)
        maximizedGroupID = nil
        move(tabID, to: newGroup.id)
        return newGroup.id
    }

    public mutating func removeGroup(_ id: UUID) {
        guard groups.count > 1, let remaining = layout.removing(id) else { return }
        if let path = leafPath(id, in: layout), path.count > 1 {
            let parent = String(path.dropLast())
            let sibling = parent + (path.last == "0" ? "1" : "0")
            var updated: [String: Double] = [:]
            for (key, value) in ratios {
                if key.hasPrefix(sibling) {
                    updated[parent + key.dropFirst(sibling.count)] = value
                } else if !key.hasPrefix(parent) {
                    updated[key] = value
                }
            }
            ratios = updated
        }
        layout = remaining
        groups.removeAll { $0.id == id }
        if activeGroupID == id { activeGroupID = layout.paneIDs[0] }
        if maximizedGroupID == id { maximizedGroupID = nil }
    }

    /// Closing a group's final tab removes its split while preserving other groups.
    public mutating func closeTab(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.tabIDs.contains(id) }),
              let tabIndex = groups[index].tabIDs.firstIndex(of: id) else { return }
        let groupID = groups[index].id
        groups[index].tabIDs.remove(at: tabIndex)
        if groups[index].selectedTabID == id {
            groups[index].selectedTabID = groups[index].tabIDs.isEmpty ? nil : groups[index].tabIDs[min(tabIndex, groups[index].tabIDs.count - 1)]
        }
        if groups[index].tabIDs.isEmpty { removeGroup(groupID) }
    }

    private func leafPath(_ id: UUID, in node: PaneLayout, path: String = "r") -> String? {
        switch node {
        case .leaf(let candidate): return candidate == id ? path : nil
        case .split(_, let first, let second):
            return leafPath(id, in: first, path: path + "0") ?? leafPath(id, in: second, path: path + "1")
        }
    }

    public mutating func mergeAll() {
        let selected = activeGroup?.selectedTabID
        let ids = layout.paneIDs.flatMap { id in groups.first(where: { $0.id == id })?.tabIDs ?? [] }
        let group = TerminalTabGroup(id: activeGroupID, tabIDs: ids, selectedTabID: selected)
        groups = [group]
        layout = .leaf(group.id)
        ratios = [:]
        maximizedGroupID = nil
    }

    public func frames(in bounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), dividerThickness: CGFloat = 0) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        func visit(_ node: PaneLayout, _ rect: CGRect, _ path: String) {
            switch node {
            case .leaf(let id): result[id] = rect
            case .split(let axis, let first, let second):
                let ratio = min(0.9, max(0.1, ratios[path] ?? 0.5))
                let divider = min(max(0, dividerThickness), axis == .vertical ? rect.width : rect.height)
                let length = max(0, (axis == .vertical ? rect.width : rect.height) - divider) * ratio
                let pair = rect.divided(atDistance: length, from: axis == .vertical ? .minXEdge : .minYEdge)
                visit(first, pair.slice, path + "0")
                let remainder = pair.remainder.divided(atDistance: divider, from: axis == .vertical ? .minXEdge : .minYEdge).remainder
                visit(second, remainder, path + "1")
            }
        }
        visit(layout, bounds, "r")
        return result
    }

    public func neighbor(_ direction: SplitDirection) -> UUID? {
        let rects = frames()
        guard let current = rects[activeGroupID] else { return nil }
        return layout.paneIDs.filter { id in
            guard id != activeGroupID, let other = rects[id] else { return false }
            switch direction {
            case .left: return other.maxX <= current.minX + 0.0001 && other.maxY > current.minY && other.minY < current.maxY
            case .right: return other.minX >= current.maxX - 0.0001 && other.maxY > current.minY && other.minY < current.maxY
            case .up: return other.maxY <= current.minY + 0.0001 && other.maxX > current.minX && other.minX < current.maxX
            case .down: return other.minY >= current.maxY - 0.0001 && other.maxX > current.minX && other.minX < current.maxX
            }
        }.min { lhs, rhs in
            let a = rects[lhs]!, b = rects[rhs]!
            return hypot(a.midX - current.midX, a.midY - current.midY) < hypot(b.midX - current.midX, b.midY - current.midY)
        }
    }
}
