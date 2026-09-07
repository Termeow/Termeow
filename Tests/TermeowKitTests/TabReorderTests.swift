import Foundation
import Testing
@testable import TermeowKit

@Test func tabReorderRequiresCrossingTheAdjacentMidpoint() {
    let ids = ["a", "b", "c"]
    let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 80, height: 22),
        "b": CGRect(x: 86, y: 0, width: 80, height: 22),
        "c": CGRect(x: 172, y: 0, width: 80, height: 22),
    ]
    let source = frames["b"]!

    #expect(
        TabReorder.targetID(
            sourceIndex: 1,
            sourceFrame: source,
            pointerX: source.midX - 8,
            orderedIDs: ids,
            frames: frames
        ) == nil
    )
    #expect(
        TabReorder.targetID(
            sourceIndex: 1,
            sourceFrame: source,
            pointerX: 40,
            orderedIDs: ids,
            frames: frames
        ) == "a"
    )
    #expect(
        TabReorder.targetID(
            sourceIndex: 1,
            sourceFrame: source,
            pointerX: source.midX + 8,
            orderedIDs: ids,
            frames: frames
        ) == nil
    )
    #expect(
        TabReorder.targetID(
            sourceIndex: 1,
            sourceFrame: source,
            pointerX: 210,
            orderedIDs: ids,
            frames: frames
        ) == "c"
    )
}
