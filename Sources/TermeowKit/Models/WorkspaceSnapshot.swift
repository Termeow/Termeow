import Foundation

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var openSessionIDs: [UUID]
    public var selectedProfileID: UUID?
    public var selectedTabIndex: Int?

    public init(
        openSessionIDs: [UUID] = [],
        selectedProfileID: UUID? = nil,
        selectedTabIndex: Int? = nil
    ) {
        self.openSessionIDs = openSessionIDs
        self.selectedProfileID = selectedProfileID
        self.selectedTabIndex = selectedTabIndex
    }
}
