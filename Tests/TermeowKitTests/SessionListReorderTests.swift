import Foundation
import Testing
@testable import TermeowKit

@Test func sessionListReorderMovesWithinAndAcrossSections() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let d = UUID()
    let start = [
        session("a", id: a),
        session("b", id: b),
        session("c", id: c, group: "Lab"),
        session("d", id: d, favorite: true),
    ]

    #expect(SessionListReorder.moving(a, in: start, to: .ungrouped(over: b))?.map(\.id) == [b, a, c, d])
    #expect(SessionListReorder.moving(b, in: start, to: .ungrouped(over: a))?.map(\.id) == [b, a, c, d])

    let favorited = SessionListReorder.moving(a, in: start, to: .favorites(over: d))
    #expect(favorited?.map(\.id) == [b, c, a, d])
    #expect(favorited?.first { $0.id == a }?.isFavorite == true)

    let grouped = SessionListReorder.moving(a, in: start, to: .group("Lab", over: c))
    #expect(grouped?.first { $0.id == a }?.groupName == "Lab")
    #expect(grouped?.first { $0.id == a }?.isFavorite == false)
    #expect(grouped?.map(\.id) == [b, a, c, d])

    let appended = SessionListReorder.moving(b, in: start, to: .group("Lab", over: nil))
    #expect(appended?.map(\.id) == [a, c, b, d])
    #expect(appended?.first { $0.id == b }?.groupName == "Lab")

    #expect(SessionListReorder.moving(a, in: start, to: .ungrouped(over: a)) == nil)
    #expect(SessionListReorder.moving(a, in: start, to: .group("  ", over: nil)) == nil)

    let sectionOrder = SessionListReorder.applyingSectionOrder([b, a], in: start)
    #expect(sectionOrder?.map(\.id) == [b, a, c, d])
    #expect(SessionListReorder.applyingSectionOrder([a, b], in: start) == nil)
}

private func session(
    _ name: String,
    id: UUID,
    group: String = "",
    favorite: Bool = false
) -> SessionProfile {
    SessionProfile(
        id: id,
        name: name,
        host: "example.com",
        username: "alice",
        groupName: group,
        isFavorite: favorite
    )
}
