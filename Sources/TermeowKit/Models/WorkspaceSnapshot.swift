import Foundation

public struct WorkspacePaneSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID

    public init(id: UUID, sessionID: UUID) {
        self.id = id
        self.sessionID = sessionID
    }
}

public struct WorkspaceTabSnapshot: Codable, Equatable, Sendable {
    public var layout: PaneLayout
    public var panes: [WorkspacePaneSnapshot]
    public var selectedPaneID: UUID

    public init(
        layout: PaneLayout,
        panes: [WorkspacePaneSnapshot],
        selectedPaneID: UUID
    ) {
        self.layout = layout
        self.panes = panes
        self.selectedPaneID = selectedPaneID
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var openSessionIDs: [UUID]
    public var selectedProfileID: UUID?
    public var selectedTabIndex: Int?
    public var tabs: [WorkspaceTabSnapshot]?
    public var tabGroups: TabGroupWorkspace?
    public var tabIDs: [UUID]?

    public init(
        openSessionIDs: [UUID] = [],
        selectedProfileID: UUID? = nil,
        selectedTabIndex: Int? = nil,
        tabs: [WorkspaceTabSnapshot]? = nil,
        tabGroups: TabGroupWorkspace? = nil,
        tabIDs: [UUID]? = nil
    ) {
        self.openSessionIDs = openSessionIDs
        self.selectedProfileID = selectedProfileID
        self.selectedTabIndex = selectedTabIndex
        self.tabs = tabs
        self.tabGroups = tabGroups
        self.tabIDs = tabIDs
    }
}
