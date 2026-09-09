import Foundation
import Testing
@testable import TermeowKit

@Test func workspaceStoreRoundTripIncludesSelectedTab() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("termeow-workspace-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let firstPaneID = UUID()
    let secondPaneID = UUID()
    let firstSessionID = UUID()
    let secondSessionID = UUID()
    let tab = WorkspaceTabSnapshot(
        layout: .split(
            axis: .vertical,
            first: .leaf(firstPaneID),
            second: .leaf(secondPaneID)
        ),
        panes: [
            WorkspacePaneSnapshot(id: firstPaneID, sessionID: firstSessionID),
            WorkspacePaneSnapshot(id: secondPaneID, sessionID: secondSessionID),
        ],
        selectedPaneID: secondPaneID
    )
    let snapshot = WorkspaceSnapshot(
        openSessionIDs: [firstSessionID, UUID(), UUID()],
        selectedProfileID: UUID(),
        selectedTabIndex: 1,
        tabs: [tab]
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
    object.removeValue(forKey: "tabs")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyData)
    #expect(decoded.openSessionIDs == snapshot.openSessionIDs)
    #expect(decoded.selectedProfileID == snapshot.selectedProfileID)
    #expect(decoded.selectedTabIndex == nil)
    #expect(decoded.tabs == nil)
}
