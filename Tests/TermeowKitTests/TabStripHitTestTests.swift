import Foundation
import CoreGraphics
import Testing
@testable import TermeowKit

@Test func tabHitTestingUsesDrawnRectsNotIndicesOrWindowOffsets() {
    let ids = (0..<8).map { _ in UUID() }
    let frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CGRect(x: 4 + $0.offset * 94, y: 4, width: 90, height: 26)) })
    #expect(TabStripHitTest.tab(at: CGPoint(x: 35, y: 15), order: ids, frames: frames) == ids[0])
    #expect(TabStripHitTest.tab(at: CGPoint(x: 411, y: 15), order: ids, frames: frames) == ids[4])
    #expect(TabStripHitTest.tab(at: CGPoint(x: 95, y: 15), order: ids, frames: frames) == nil)
    #expect(TabStripHitTest.tab(at: CGPoint(x: 35, y: 35), order: ids, frames: frames) == nil)
}

@Test func tabInsertionUsesBothHalvesAndPreservesAdjacentMoves() {
    let ids = (0..<3).map { _ in UUID() }
    let frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CGRect(x: $0.offset * 100, y: 0, width: 96, height: 30)) })
    let beforeSecond = TabStripHitTest.insertion(at: 120, order: ids, frames: frames, excluding: ids[2])
    let afterSecond = TabStripHitTest.insertion(at: 175, order: ids, frames: frames, excluding: ids[0])
    #expect(beforeSecond.before == ids[1])
    #expect(afterSecond.before == ids[2])
    var workspace = TabGroupWorkspace(tabIDs: ids)
    workspace.move(ids[2], to: workspace.activeGroupID, before: beforeSecond.before)
    #expect(workspace.activeGroup?.tabIDs == [ids[0], ids[2], ids[1]])
}

@Test func insertionHandlesUnequalWidthsAndAppendsAtEnd() {
    let a = UUID(), b = UUID(), c = UUID()
    let frames = [a: CGRect(x: 4, y: 4, width: 90, height: 26), b: CGRect(x: 98, y: 4, width: 220, height: 26)]
    #expect(TabStripHitTest.insertion(at: 180, order: [a, b], frames: frames, excluding: c).before == b)
    #expect(TabStripHitTest.insertion(at: 250, order: [a, b], frames: frames, excluding: c).before == nil)
    #expect(TabStripHitTest.insertion(at: 5, order: [], frames: [:], excluding: c).before == nil)
}
