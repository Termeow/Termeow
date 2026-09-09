import Foundation
import Testing
@testable import TermeowKit

@Test func movingTabsPreservesIdentityAndCollapsesVacatedGroups() throws {
    let a = UUID(), b = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a, b])
    let original = workspace.activeGroupID
    let splitResult = workspace.split(groupID: original, direction: .right, moving: b)
    let other = try #require(splitResult)
    #expect(workspace.groups.first { $0.id == original }?.tabIDs == [a])
    #expect(workspace.activeGroup?.tabIDs == [b])
    workspace.move(a, to: other, before: b)
    #expect(workspace.groups.count == 1)
    #expect(workspace.layout == .leaf(other))
    #expect(workspace.activeGroup?.tabIDs == [a, b])
    #expect(workspace.activeGroup?.selectedTabID == a)
}

@Test func groupNavigationUsesGeometryAndDoesNotWrap() throws {
    var workspace = TabGroupWorkspace()
    let left = workspace.activeGroupID
    let rightResult = workspace.split(groupID: left, direction: .right)
    let right = try #require(rightResult)
    let bottomResult = workspace.split(groupID: right, direction: .down)
    let bottom = try #require(bottomResult)
    #expect(workspace.neighbor(.up) == right)
    #expect(workspace.neighbor(.left) == left)
    #expect(workspace.neighbor(.down) == nil)
    workspace.activate(right)
    #expect(workspace.neighbor(.down) == bottom)
    #expect(workspace.neighbor(.right) == nil)
}

@Test func collapsingGroupPreservesSurvivingDividerProportions() throws {
    var workspace = TabGroupWorkspace()
    let left = workspace.activeGroupID
    let rightResult = workspace.split(groupID: left, direction: .right)
    let right = try #require(rightResult)
    _ = workspace.split(groupID: right, direction: .down)
    workspace.ratios = ["r": 0.3, "r1": 0.7]
    workspace.removeGroup(left)
    #expect(workspace.ratios == ["r": 0.7])
    #expect(workspace.frames()[right]?.height == 0.7)
}

@Test func groupLayoutAndSelectionsRoundTripAndMerge() throws {
    let a = UUID(), b = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a, b])
    let first = workspace.activeGroupID
    let splitResult = workspace.split(groupID: first, direction: .left, moving: b)
    let second = try #require(splitResult)
    workspace.ratios["r"] = 0.4
    workspace.maximizedGroupID = second
    let restored = try JSONDecoder().decode(TabGroupWorkspace.self, from: JSONEncoder().encode(workspace))
    #expect(restored == workspace)
    workspace.mergeAll()
    #expect(workspace.activeGroup?.tabIDs == [b, a])
    #expect(workspace.activeGroup?.selectedTabID == b)
    #expect(workspace.ratios.isEmpty)
    #expect(workspace.maximizedGroupID == nil)
}

@Test func reconcileRepairsMissingTabsAndEmptyWorkspace() {
    let a = UUID(), b = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a])
    workspace.reconcile(tabIDs: [b], selectedTabID: nil)
    #expect(workspace.activeGroup?.tabIDs == [b])
    #expect(workspace.activeGroup?.selectedTabID == b)
    workspace.groups = []
    workspace.reconcile(tabIDs: [a], selectedTabID: a)
    #expect(workspace.activeGroup?.selectedTabID == a)
}

@Test func emptyGroupsAndGroupLimitAreExplicit() {
    var workspace = TabGroupWorkspace()
    for _ in 1..<16 { _ = workspace.split(groupID: workspace.activeGroupID, direction: .right) }
    #expect(workspace.groups.count == 16)
    let overflow = workspace.split(groupID: workspace.activeGroupID, direction: .down)
    #expect(overflow == nil)
    #expect(workspace.groups.allSatisfy { $0.tabIDs.isEmpty })
}

@Test func invalidGroupLayoutIsRepairedWithoutLosingTabs() {
    let a = UUID(), b = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a, b])
    workspace.layout = .leaf(UUID())
    workspace.reconcile(tabIDs: [a, b], selectedTabID: b)
    #expect(workspace.layout.paneIDs == workspace.groups.map(\.id))
    #expect(workspace.activeGroup?.tabIDs == [a, b])
    #expect(workspace.activeGroup?.selectedTabID == b)
}

@Test func reorderingWithinGroupDoesNotDuplicateTabs() {
    let a = UUID(), b = UUID(), c = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a, b, c])
    workspace.move(c, to: workspace.activeGroupID, before: b)
    #expect(workspace.activeGroup?.tabIDs == [a, c, b])
    workspace.move(c, to: workspace.activeGroupID, before: c)
    #expect(workspace.activeGroup?.tabIDs == [a, c, b])
}

@Test func outerEdgeSplitsWrapExistingGroupsAndPreserveRatios() throws {
    for direction in SplitDirection.allCases {
        let a = UUID(), b = UUID(), c = UUID()
        var workspace = TabGroupWorkspace(tabIDs: [a, b, c])
        let left = workspace.activeGroupID
        _ = workspace.split(groupID: left, direction: .right, moving: c)
        workspace.ratios["r"] = 0.35
        let oldLayout = workspace.layout
        let result = workspace.splitWorkspace(direction: direction, moving: b)
        let added = try #require(result)
        #expect(workspace.layout == .split(axis: direction.axis, first: direction.before ? .leaf(added) : oldLayout, second: direction.before ? oldLayout : .leaf(added)))
        #expect(workspace.ratios[direction.before ? "r1" : "r0"] == 0.35)
        #expect(workspace.activeGroup?.tabIDs == [b])
        #expect(Set(workspace.groups.flatMap(\.tabIDs)) == Set([a, b, c]))
    }
}

@Test func outerEdgeRefusesLastSessionAndInvalidSource() {
    let a = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a])
    let result = workspace.splitWorkspace(direction: .left, moving: a)
    #expect(result == nil)
    let invalid = workspace.splitWorkspace(direction: .left, moving: UUID())
    #expect(invalid == nil)
    #expect(workspace.groups.count == 1)
}

@Test func nativeDropFramesMatchVisibleDividerGaps() throws {
    var workspace = TabGroupWorkspace()
    let first = workspace.activeGroupID
    let result = workspace.split(groupID: first, direction: .right)
    let second = try #require(result)
    let frames = workspace.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 600), dividerThickness: 6)
    #expect(frames[first] == CGRect(x: 0, y: 0, width: 497, height: 600))
    #expect(frames[second] == CGRect(x: 503, y: 0, width: 497, height: 600))
}

@Test func closingOnlyTabInSplitCollapsesOnlyItsGroup() throws {
    let a = UUID(), b = UUID(), c = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a, b, c])
    let original = workspace.activeGroupID
    let split = workspace.split(groupID: original, direction: .right, moving: c)
    let right = try #require(split)
    workspace.closeTab(c)
    #expect(workspace.groups.count == 1)
    #expect(workspace.layout == .leaf(original))
    #expect(!workspace.layout.contains(right))
    #expect(workspace.activeGroupID == original)
    #expect(workspace.activeGroup?.tabIDs == [a, b])
    #expect(workspace.activeGroup?.selectedTabID == a)
}

@Test func closingInactiveSplitDoesNotChangeOtherGroupSelection() throws {
    let a = UUID(), b = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a, b])
    let original = workspace.activeGroupID
    let split = workspace.split(groupID: original, direction: .down, moving: b)
    let bottom = try #require(split)
    workspace.closeTab(a)
    #expect(workspace.activeGroupID == bottom)
    #expect(workspace.activeGroup?.selectedTabID == b)
    #expect(workspace.layout == .leaf(bottom))
}

@Test func closingTabSelectsAdjacentTabAndLastTabLeavesSingleEmptyWorkspace() {
    let a = UUID(), b = UUID(), c = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a, b, c])
    workspace.reconcile(tabIDs: [a, b, c], selectedTabID: b)
    workspace.closeTab(b)
    #expect(workspace.activeGroup?.tabIDs == [a, c])
    #expect(workspace.activeGroup?.selectedTabID == c)
    workspace.closeTab(c)
    #expect(workspace.activeGroup?.selectedTabID == a)
    workspace.closeTab(a)
    #expect(workspace.groups.count == 1)
    #expect(workspace.activeGroup?.tabIDs.isEmpty == true)
    #expect(workspace.activeGroup?.selectedTabID == nil)
}

@Test func closingZoomedNestedGroupRestoresRemainingLayoutAndRatios() throws {
    let a = UUID(), b = UUID(), c = UUID()
    var workspace = TabGroupWorkspace(tabIDs: [a, b, c])
    let left = workspace.activeGroupID
    let split = workspace.split(groupID: left, direction: .right, moving: b)
    let right = try #require(split)
    _ = workspace.split(groupID: right, direction: .down)
    workspace.ratios = ["r": 0.3, "r1": 0.7]
    workspace.maximizedGroupID = left
    workspace.closeTab(a)
    #expect(workspace.layout.contains(left))
    workspace.closeTab(c)
    #expect(!workspace.layout.contains(left))
    #expect(workspace.maximizedGroupID == nil)
    #expect(workspace.ratios == ["r": 0.7])
    #expect(workspace.groups.flatMap(\.tabIDs) == [b])
}
