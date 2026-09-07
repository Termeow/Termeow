import Foundation
import Testing
@testable import TermeowKit

@Test func workspaceStoreRoundTripIncludesSelectedTab() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("termeow-workspace-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let snapshot = WorkspaceSnapshot(
        openSessionIDs: [UUID(), UUID(), UUID()],
        selectedProfileID: UUID(),
        selectedTabIndex: 1
    )
    let store = WorkspaceStore(fileURL: url)

    try store.save(snapshot)
    #expect(try store.load() == snapshot)
}

@Test func workspaceSnapshotDecodesWithoutSelectedTabIndex() throws {
    let snapshot = WorkspaceSnapshot(
        openSessionIDs: [UUID()],
        selectedProfileID: UUID(),
        selectedTabIndex: 0
    )
    let encoded = try JSONEncoder().encode(snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "selectedTabIndex")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyData)
    #expect(decoded.openSessionIDs == snapshot.openSessionIDs)
    #expect(decoded.selectedProfileID == snapshot.selectedProfileID)
    #expect(decoded.selectedTabIndex == nil)
}
