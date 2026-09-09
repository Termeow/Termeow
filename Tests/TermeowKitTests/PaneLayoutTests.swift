import Foundation
import Testing
@testable import TermeowKit

@Test func paneLayoutSplitsNestedLeavesInDisplayOrder() throws {
    let first = UUID()
    let second = UUID()
    let third = UUID()

    let initial = PaneLayout.leaf(first)
    let vertical = try #require(
        initial.splitting(paneID: first, newPaneID: second, axis: .vertical)
    )
    let nested = try #require(
        vertical.splitting(paneID: second, newPaneID: third, axis: .horizontal)
    )

    #expect(nested.paneIDs == [first, second, third])
    #expect(nested.contains(second))
    #expect(nested == .split(
        axis: .vertical,
        first: .leaf(first),
        second: .split(axis: .horizontal, first: .leaf(second), second: .leaf(third))
    ))
}

@Test func paneLayoutRemovalCollapsesEmptyBranches() throws {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let layout = PaneLayout.split(
        axis: .vertical,
        first: .leaf(first),
        second: .split(axis: .horizontal, first: .leaf(second), second: .leaf(third))
    )

    let withoutSecond = try #require(layout.removing(second))
    #expect(withoutSecond == .split(axis: .vertical, first: .leaf(first), second: .leaf(third)))
    #expect(PaneLayout.leaf(first).removing(first) == nil)
}

@Test func paneLayoutRetentionRepairsUnavailableSavedPanes() throws {
    let first = UUID()
    let missing = UUID()
    let last = UUID()
    let layout = PaneLayout.split(
        axis: .horizontal,
        first: .split(axis: .vertical, first: .leaf(first), second: .leaf(missing)),
        second: .leaf(last)
    )

    let retained = try #require(layout.retaining([first, last]))
    #expect(retained == .split(axis: .horizontal, first: .leaf(first), second: .leaf(last)))
}

@Test func paneLayoutMapsIDsAndRoundTripsThroughJSON() throws {
    let first = UUID()
    let second = UUID()
    let replacementFirst = UUID()
    let replacementSecond = UUID()
    let replacements = [first: replacementFirst, second: replacementSecond]
    let layout = PaneLayout.split(axis: .vertical, first: .leaf(first), second: .leaf(second))

    let mapped = layout.mappingPaneIDs { replacements[$0] ?? $0 }
    #expect(mapped.paneIDs == [replacementFirst, replacementSecond])

    let encoded = try JSONEncoder().encode(mapped)
    #expect(try JSONDecoder().decode(PaneLayout.self, from: encoded) == mapped)
}
