import AppKit
import Observation
import SwiftUI
import TermeowKit

@MainActor
@Observable
final class AppModel {
    var profiles: [SessionProfile] = []
    var sessionGroups: [String] = []
    var tabs: [WorkspaceTab] = []
    var tabGroups = TabGroupWorkspace()
    var groupPendingClosure: UUID?
    var selectedProfileID: SessionProfile.ID?
    var selectedTabID: WorkspaceTab.ID?
    var searchText = ""
    var editor: SessionEditorState?
    var forwardingController: ConnectionController?
    var sessionPendingDeletion: SessionProfile?
    var tabPendingClosure: TabCloseRequest?
    var panePendingClosure: PaneCloseRequest?
    var hostKeyPrompt: HostKeyPromptState?
    @ObservationIgnored
    private var hostKeyContinuation: CheckedContinuation<HostKeyDecision, Never>?
    var findBarVisible = false
    var findQuery = ""
    var findCaseSensitive = false
    var findMatchIndex = 0
    var findMatchTotal = 0
    var chromePreferences = WorkspaceChromePreferences.load()
    var statusMessage: String?
    var typography = TerminalTypography.load()
    var colorSchemeID = TerminalColorSchemeID.load()
    var scrollback = TerminalScrollback.load()

    @ObservationIgnored
    private var sftpWindows: [UUID: SFTPWindowController] = [:]

    let sessionStore: SessionStore
    let hostKeyStore: HostKeyStore
    let keychain = KeychainStore()
    let workspaceStore: WorkspaceStore

    init() {
        sessionStore = SessionStore(fileURL: (try? SessionStore.defaultURL()) ?? URL(fileURLWithPath: "/tmp/termeow-sessions.json"))
        hostKeyStore = HostKeyStore(fileURL: (try? HostKeyStore.defaultURL()) ?? URL(fileURLWithPath: "/tmp/termeow-host-keys.json"))
        workspaceStore = WorkspaceStore(fileURL: (try? WorkspaceStore.defaultURL()) ?? URL(fileURLWithPath: "/tmp/termeow-workspace.json"))
        reload()
    }

    var selectedProfile: SessionProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var sftpContextProfile: SessionProfile? {
        selectedTab?.controller.profile ?? selectedProfile
    }

    var selectedPaneCount: Int {
        tabGroups.groups.count
    }

    var sidebarVisible: Bool {
        get { chromePreferences.sidebarVisible }
        set {
            guard newValue != chromePreferences.sidebarVisible else { return }
            chromePreferences.sidebarVisible = newValue
            chromePreferences.save()
        }
    }

    var statusBarVisible: Bool {
        get { chromePreferences.statusBarVisible }
        set {
            guard newValue != chromePreferences.statusBarVisible else { return }
            chromePreferences.statusBarVisible = newValue
            chromePreferences.save()
        }
    }

    var filteredProfiles: [SessionProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.host.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
                || $0.groupName.localizedCaseInsensitiveContains(query)
                || String($0.port).localizedCaseInsensitiveContains(query)
        }
    }

    var sessionGroupNames: [String] {
        normalizedSessionGroupNames(sessionGroups + profiles.map(\.groupName))
    }

    func tabStates(for profileID: SessionProfile.ID) -> [SSHConnectionState] {
        tabs.compactMap { $0.connectionState(for: profileID) }
    }

    func reload() {
        do {
            let library = try sessionStore.loadLibrary()
            profiles = library.profiles
            sessionGroups = normalizedSessionGroupNames(library.groups + library.profiles.map(\.groupName))
        } catch {
            AppLog.storage.error("Failed to load sessions")
            profiles = []
            sessionGroups = []
        }
        let snapshot = (try? workspaceStore.load()) ?? WorkspaceSnapshot()
        selectedProfileID = snapshot.selectedProfileID ?? profiles.first?.id
        var restoredTabIDs: [Int: WorkspaceTab.ID] = [:]
        if let tabSnapshots = snapshot.tabs, !tabSnapshots.isEmpty {
            for (index, tabSnapshot) in tabSnapshots.enumerated() {
                if let tab = restoredTab(from: tabSnapshot) {
                    tabs.append(tab)
                    restoredTabIDs[index] = tab.id
                }
            }
        } else {
            for (index, sessionID) in snapshot.openSessionIDs.enumerated() {
                if let profile = profiles.first(where: { $0.id == sessionID }) {
                    restoredTabIDs[index] = openTab(for: profile, connect: false, persistWorkspace: false)
                }
            }
        }
        selectedTabID = snapshot.selectedTabIndex.flatMap { restoredTabIDs[$0] } ?? tabs.first?.id
        // Upgrade the first split-pane preview to one session per tab.
        let oldSelected = selectedTab?.controller.id
        tabs = tabs.flatMap { tab in
            tab.allControllers.map { WorkspaceTab(controller: $0) }
        }
        if let savedIDs = snapshot.tabIDs, savedIDs.count == tabs.count {
            tabs = zip(savedIDs, tabs).map { WorkspaceTab(id: $0.0, controller: $0.1.controller) }
        }
        selectedTabID = tabs.first(where: { $0.controller.id == oldSelected })?.id ?? tabs.first?.id
        tabGroups = snapshot.tabGroups ?? TabGroupWorkspace(tabIDs: tabs.map(\.id))
        if snapshot.tabGroups != nil { selectedTabID = tabGroups.activeGroup?.selectedTabID }
        tabGroups.reconcile(tabIDs: tabs.map(\.id), selectedTabID: selectedTabID)
        selectedTabID = tabGroups.activeGroup?.selectedTabID
    }

    func setTypography(_ typography: TerminalTypography) {
        let value = typography.clamped()
        guard value != self.typography else { return }
        self.typography = value
        value.save()
    }

    func setColorSchemeID(_ id: TerminalColorSchemeID) {
        guard id != colorSchemeID else { return }
        colorSchemeID = id
        id.save()
    }

    func setScrollback(_ scrollback: TerminalScrollback) {
        let value = scrollback.clamped()
        guard value != self.scrollback else { return }
        self.scrollback = value
        value.save()
        tabs.flatMap(\.allControllers).forEach { $0.applyScrollback(value) }
    }

    func persist() {
        tabGroups.reconcile(tabIDs: tabs.map(\.id), selectedTabID: selectedTabID)
        do {
            try sessionStore.saveLibrary(SessionLibrary(profiles: profiles, groups: sessionGroupNames))
            try workspaceStore.save(
                WorkspaceSnapshot(
                    openSessionIDs: tabs.map(\.sessionID),
                    selectedProfileID: selectedProfileID,
                    selectedTabIndex: selectedTabID.flatMap { selectedID in
                        tabs.firstIndex { $0.id == selectedID }
                    },
                    tabs: tabs.map(\.snapshot),
                    tabGroups: tabGroups,
                    tabIDs: tabs.map(\.id)
                )
            )
        } catch {
            AppLog.storage.error("Failed to persist sessions")
        }
    }

    func beginNewSession(inGroup groupName: String = "") {
        editor = SessionEditorState(
            profile: SessionProfile(
                name: String(localized: "New Session"),
                host: "",
                username: "",
                groupName: groupName
            ),
            secret: ""
        )
    }

    func editSelected() {
        guard let profile = selectedProfile else { return }
        let secret = profile.authMethod == .agent ? "" : (try? keychain.secret(id: profile.credentialID)) ?? ""
        editor = SessionEditorState(profile: profile, secret: secret)
    }

    func duplicateSelected() {
        guard let profile = selectedProfile else { return }
        var copy = profile
        copy.id = UUID()
        copy.credentialID = UUID()
        copy.isFavorite = false
        copy.lastUsedAt = nil
        let sourceName = profile.name.isEmpty ? profile.displayName : profile.name
        copy.name = String(format: String(localized: "%@ copy"), sourceName)
        if profile.authMethod != .agent, let secret = try? keychain.secret(id: profile.credentialID) {
            try? keychain.saveSecret(secret, id: copy.credentialID)
        }
        profiles.append(copy)
        selectedProfileID = copy.id
        persist()
    }

    func deleteSelected() {
        sessionPendingDeletion = selectedProfile
    }

    func confirmDelete(_ profile: SessionProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        try? keychain.deleteSecret(id: profile.credentialID)
        let removedTabIDs = Set(tabs.lazy.filter { $0.contains(profileID: profile.id) }.map(\.id))
        let affectedGroups = tabGroups.groups.filter { !$0.tabIDs.allSatisfy { !removedTabIDs.contains($0) } }.map(\.id)
        tabs.lazy.filter { $0.contains(profileID: profile.id) }.forEach { $0.disconnectAll() }
        tabs.removeAll { $0.contains(profileID: profile.id) }
        tabGroups.reconcile(tabIDs: tabs.map(\.id), selectedTabID: nil)
        for id in affectedGroups where tabGroups.groups.first(where: { $0.id == id })?.tabIDs.isEmpty == true {
            tabGroups.removeGroup(id)
        }
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
        }
        if let selectedTabID, removedTabIDs.contains(selectedTabID) {
            self.selectedTabID = tabGroups.activeGroup?.selectedTabID
        }
        sessionPendingDeletion = nil
        persist()
    }

    func rename(_ profile: SessionProfile, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        updateProfile(profile.id) { $0.name = trimmedName }
    }

    func toggleFavorite(_ profile: SessionProfile) {
        updateProfile(profile.id) { $0.isFavorite.toggle() }
    }

    func move(_ profile: SessionProfile, toGroup groupName: String) {
        let trimmedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        addSessionGroupIfNeeded(trimmedGroupName)
        updateProfile(profile.id) { $0.groupName = trimmedGroupName }
    }

    @discardableResult
    func moveSession(_ id: SessionProfile.ID, to placement: SessionListPlacement) -> Bool {
        if case .group(let name, _) = placement {
            addSessionGroupIfNeeded(name)
        }
        guard let moved = SessionListReorder.moving(id, in: profiles, to: placement) else { return false }
        profiles = moved
        if let profile = profiles.first(where: { $0.id == id }) {
            synchronizeOpenTabs(with: profile)
        }
        persist()
        return true
    }

    @discardableResult
    func reorderSessions(inSection orderedIDs: [SessionProfile.ID]) -> Bool {
        guard let moved = SessionListReorder.applyingSectionOrder(orderedIDs, in: profiles) else { return false }
        profiles = moved
        persist()
        return true
    }

    func canUseSessionGroupName(_ name: String, excluding currentName: String? = nil) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        return !sessionGroupNames.contains { existingName in
            guard existingName.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame else {
                return false
            }
            guard let currentName else { return true }
            return existingName.localizedCaseInsensitiveCompare(currentName) != .orderedSame
        }
    }

    func createSessionGroup(_ name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canUseSessionGroupName(trimmedName) else { return }
        sessionGroups.append(trimmedName)
        persist()
    }

    func renameSessionGroup(_ groupName: String, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canUseSessionGroupName(trimmedName, excluding: groupName) else { return }
        sessionGroups.removeAll {
            $0.localizedCaseInsensitiveCompare(groupName) == .orderedSame
        }
        sessionGroups.append(trimmedName)
        for index in profiles.indices
        where profiles[index].groupName.localizedCaseInsensitiveCompare(groupName) == .orderedSame {
            profiles[index].groupName = trimmedName
            synchronizeOpenTabs(with: profiles[index])
        }
        persist()
    }

    func deleteSessionGroup(_ groupName: String) {
        sessionGroups.removeAll {
            $0.localizedCaseInsensitiveCompare(groupName) == .orderedSame
        }
        for index in profiles.indices
        where profiles[index].groupName.localizedCaseInsensitiveCompare(groupName) == .orderedSame {
            profiles[index].groupName = ""
            synchronizeOpenTabs(with: profiles[index])
        }
        persist()
    }

    func copySSHCommand(_ profile: SessionProfile) {
        if let error = PortForwardRule.validationError(in: profile.portForwards) {
            statusMessage = error
            return
        }
        let route: [SessionProfile]
        do {
            route = try SSHConnectionRoute.resolve(destination: profile, profiles: profiles)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        guard !route.contains(where: { $0.authMethod == .agent }) else {
            statusMessage = "Copy SSH Command is unavailable for agent routes."
            return
        }
        let destination = shellArgument("\(profile.username)@\(profile.host)")
        let jumps = route.dropLast().map { hop in
            let host = hop.host.contains(":") ? "[\(hop.host)]" : hop.host
            return "\(hop.username)@\(host):\(hop.port)"
        }.joined(separator: ",")
        let proxy = jumps.isEmpty ? "" : " -J \(shellArgument(jumps))"
        let port = profile.port == 22 ? "" : " -p \(profile.port)"
        let forwarding = profile.portForwards.filter(\.isEnabled).flatMap(\.sshArguments).map(shellArgument).joined(separator: " ")
        let command = "ssh\(proxy)\(port)\(forwarding.isEmpty ? "" : " " + forwarding) -- \(destination)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        statusMessage = String(localized: "SSH command copied")
    }

    func saveEditor() {
        guard var state = editor else { return }
        state.profile.host = state.profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        state.profile.username = state.profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        state.profile.name = state.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.profile.groupName = state.profile.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.profile.isValidForSaving else {
            editor = state
            return
        }
        if let error = PortForwardRule.validationError(in: state.profile.portForwards) {
            statusMessage = error
            return
        }
        do {
            _ = try SSHConnectionRoute.resolve(destination: state.profile, profiles: profiles)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        if state.profile.name.isEmpty {
            state.profile.name = state.profile.displayName
        }
        addSessionGroupIfNeeded(state.profile.groupName)
        if let index = profiles.firstIndex(where: { $0.id == state.profile.id }) {
            profiles[index] = state.profile
            synchronizeOpenTabs(with: state.profile)
        } else {
            profiles.append(state.profile)
        }
        if state.profile.authMethod == .agent || state.secret.isEmpty {
            try? keychain.deleteSecret(id: state.profile.credentialID)
        } else {
            try? keychain.saveSecret(state.secret, id: state.profile.credentialID)
        }
        selectedProfileID = state.profile.id
        editor = nil
        persist()
    }

    func connectSelected() {
        guard let profile = selectedProfile else { return }
        connect(profile)
    }

    func openSelectedInNewTab() {
        guard let profile = selectedProfile else { return }
        openSessionInNewTab(profile)
    }

    func openSelectedSFTP() {
        guard let profile = sftpContextProfile else { return }
        openSFTP(profile)
    }

    func openSFTP(_ profile: SessionProfile) {
        selectedProfileID = profile.id
        let route: [SSHConnectionHop]
        do {
            route = try prepareConnectionRoute(for: profile)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        let promptCoordinator = SFTPHostKeyPromptCoordinator()
        let bridge = SFTPHostKeyBridge(coordinator: promptCoordinator)
        let service = CitadelSFTPService(
            profile: profile,
            secret: route.last?.secret ?? "",
            hostKeyStore: hostKeyStore,
            jumpHosts: Array(route.dropLast())
        ) { check in
            await bridge.prompt(check)
        }
        let browser = SFTPBrowserModel(profile: profile, service: service)
        let id = UUID()
        let controller = SFTPWindowController(
            id: id,
            browser: browser,
            promptCoordinator: promptCoordinator
        ) { [weak self] id in
            self?.sftpWindows.removeValue(forKey: id)
        }
        sftpWindows[id] = controller
        controller.showWindow(nil)
    }

    func prepareConnectionRoute(for profile: SessionProfile) throws -> [SSHConnectionHop] {
        try SSHConnectionRoute.resolve(destination: profile, profiles: profiles).map { hop in
            if hop.authMethod == .agent { return SSHConnectionHop(profile: hop, secret: "") }
            do {
                return SSHConnectionHop(profile: hop, secret: try keychain.secret(id: hop.credentialID) ?? "")
            } catch {
                if hop.id == profile.id { throw SSHError.missingCredential }
                throw SSHError.jumpHostFailed(hop.displayName, .missingCredential)
            }
        }
    }

    func closeSelectedTabOrSFTPWindow() {
        var targetWindow = NSApp.keyWindow
        if let sheetParent = targetWindow?.sheetParent {
            targetWindow = sheetParent
        }
        if let targetWindow,
           sftpWindows.values.contains(where: { $0.window === targetWindow }) {
            targetWindow.performClose(nil)
            return
        }
        closeSelectedTab()
    }

    func openSessionInNewTab(_ profile: SessionProfile) {
        selectedProfileID = profile.id
        let currentProfile = markSessionUsed(profile.id) ?? profile
        openTab(for: currentProfile, connect: true)
    }

    func connect(_ profile: SessionProfile) {
        selectedProfileID = profile.id
        let currentProfile = markSessionUsed(profile.id) ?? profile
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
           tabs[index].controller.canReuseForConnection {
            let paneID = tabs[index].selectedPaneID
            tabs[index].controller.disconnect()
            let controller = ConnectionController(id: paneID, profile: currentProfile, model: self)
            tabs[index].replaceController(controller, for: paneID)
            persist()
            controller.connect()
            return
        }
        openTab(for: currentProfile, connect: true)
    }

    @discardableResult
    func openTab(
        for profile: SessionProfile,
        connect: Bool,
        persistWorkspace: Bool = true
    ) -> WorkspaceTab.ID {
        let tab = WorkspaceTab(controller: ConnectionController(profile: profile, model: self))
        tabs.append(tab)
        selectedTabID = tab.id
        if persistWorkspace {
            persist()
        }
        if connect {
            tab.controller.connect()
        }
        return tab.id
    }

    func selectTab(_ id: WorkspaceTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        persist()
    }

    func selectTab(at index: Int) {
        guard let ids = tabGroups.activeGroup?.tabIDs, ids.indices.contains(index) else { return }
        selectTab(ids[index])
        focusActiveTerminal()
    }

    func reorderTab(_ id: WorkspaceTab.ID, over targetID: WorkspaceTab.ID) {
        guard let targetIndex = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        moveTab(id, to: targetIndex)
    }

    func moveTab(_ id: WorkspaceTab.ID, by offset: Int) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        moveTab(id, to: sourceIndex + offset)
    }

    func canMoveTab(_ id: WorkspaceTab.ID, by offset: Int) -> Bool {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return tabs.indices.contains(sourceIndex + offset)
    }

    private func moveTab(_ id: WorkspaceTab.ID, to destinationIndex: Int) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              tabs.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: destinationIndex)
        persist()
    }

    func closeSelectedTab() {
        guard let id = selectedTabID else { return }
        requestCloseTab(id)
    }

    func requestCloseTab(_ id: WorkspaceTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        guard tab.requiresCloseConfirmation else {
            closeTab(id)
            return
        }
        tabPendingClosure = TabCloseRequest(id: id, title: tab.controller.title)
    }

    func confirmCloseTab(_ request: TabCloseRequest) {
        tabPendingClosure = nil
        for id in [request.id] + request.extraIDs { closeTab(id) }
    }

    func cancelCloseTab() {
        tabPendingClosure = nil
    }

    private func closeTab(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        tabs[index].disconnectAll()
        tabs.remove(at: index)
        tabGroups.closeTab(id)
        if wasSelected {
            selectedTabID = tabGroups.activeGroup?.selectedTabID
        }
        persist()
        focusActiveTerminal()
    }

    func reconnectTab(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let paneID = tabs[index].selectedPaneID
        let storedProfile = tabs[index].controller.profile
        let profile = markSessionUsed(storedProfile.id) ?? storedProfile
        tabs[index].controller.disconnect()
        let controller = ConnectionController(id: paneID, profile: profile, model: self)
        tabs[index].replaceController(controller, for: paneID)
        selectedProfileID = profile.id
        selectedTabID = id
        persist()
        controller.connect()
    }

    func disconnectTab(_ id: WorkspaceTab.ID) {
        tabs.first(where: { $0.id == id })?.controller.disconnect()
    }

    func duplicateTab(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let source = tabs[index]
        var paneIDMap: [UUID: UUID] = [:]
        var controllers: [UUID: ConnectionController] = [:]
        for sourcePaneID in source.layout.paneIDs {
            guard let sourceController = source.controller(for: sourcePaneID) else { continue }
            let paneID = UUID()
            paneIDMap[sourcePaneID] = paneID
            let currentProfile = profiles.first(where: { $0.id == sourceController.profile.id })
                ?? sourceController.profile
            controllers[paneID] = ConnectionController(id: paneID, profile: currentProfile, model: self)
        }
        guard controllers.count == source.paneCount,
              let selectedPaneID = paneIDMap[source.selectedPaneID]
        else { return }
        let layout = source.layout.mappingPaneIDs { paneIDMap[$0] ?? $0 }
        let duplicate = WorkspaceTab(
            layout: layout,
            controllers: controllers,
            selectedPaneID: selectedPaneID
        )
        tabs.insert(duplicate, at: index + 1)
        selectedProfileID = duplicate.controller.profile.id
        selectedTabID = duplicate.id
        persist()
        duplicate.allControllers.forEach { $0.connect() }
    }

    func closeOtherTabs(keeping id: WorkspaceTab.ID) {
        guard let group = tabGroups.groups.first(where: { $0.tabIDs.contains(id) }) else { return }
        requestCloseTabs(group.tabIDs.filter { $0 != id })
    }

    func closeTabsToRight(of id: WorkspaceTab.ID) {
        guard let group = tabGroups.groups.first(where: { $0.tabIDs.contains(id) }),
              let index = group.tabIDs.firstIndex(of: id) else { return }
        requestCloseTabs(Array(group.tabIDs.dropFirst(index + 1)))
    }

    func hasTabsToRight(of id: WorkspaceTab.ID) -> Bool {
        guard let group = tabGroups.groups.first(where: { $0.tabIDs.contains(id) }),
              let index = group.tabIDs.firstIndex(of: id) else { return false }
        return index + 1 < group.tabIDs.count
    }

    private func requestCloseTabs(_ ids: [UUID]) {
        guard let first = ids.first else { return }
        if tabs.contains(where: { ids.contains($0.id) && $0.requiresCloseConfirmation }) {
            tabPendingClosure = TabCloseRequest(id: first, title: String(localized: "Selected Tabs"), extraIDs: Array(ids.dropFirst()))
        } else { ids.forEach { closeTab($0) } }
    }

    func splitSelectedPane(_ axis: PaneSplitAxis) {
        createGroup(axis == .vertical ? .right : .down)
    }

    func activateGroup(_ id: UUID, focus: Bool = true) {
        tabGroups.activate(id)
        selectedTabID = tabGroups.activeGroup?.selectedTabID
        if let profile = selectedTab?.controller.profile { selectedProfileID = profile.id }
        persist()
        if focus { focusActiveTerminal() }
    }

    func focusActiveTerminal() {
        DispatchQueue.main.async { [weak self] in self?.selectedTab?.controller.focusTerminal() }
    }

    func createGroup(_ direction: SplitDirection, moving tabID: UUID? = nil) {
        guard let id = tabGroups.split(groupID: tabGroups.activeGroupID, direction: direction, moving: tabID) else { return }
        activateGroup(id)
    }

    func moveSessionTab(_ tabID: UUID, to groupID: UUID, direction: SplitDirection? = nil, before targetID: UUID? = nil) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if let direction {
            // Dropping the only tab on its own edge would just create an empty region.
            if let group = tabGroups.groups.first(where: { $0.id == groupID }), group.tabIDs == [tabID] { return }
            guard let newID = tabGroups.split(groupID: groupID, direction: direction, moving: tabID) else { return }
            activateGroup(newID)
        } else {
            tabGroups.move(tabID, to: groupID, before: targetID)
            activateGroup(groupID)
        }
    }

    func focusGroup(_ direction: SplitDirection) {
        guard let neighbor = tabGroups.neighbor(direction) else { return }
        activateGroup(neighbor)
    }

    func moveSessionTabToWorkspaceEdge(_ tabID: UUID, direction: SplitDirection) {
        guard tabs.contains(where: { $0.id == tabID }),
              let id = tabGroups.splitWorkspace(direction: direction, moving: tabID) else { return }
        activateGroup(id)
    }

    func mergeAllGroups() {
        tabGroups.mergeAll()
        activateGroup(tabGroups.activeGroupID)
    }

    func toggleGroupZoom() {
        tabGroups.maximizedGroupID = tabGroups.maximizedGroupID == nil ? tabGroups.activeGroupID : nil
        persist()
        focusActiveTerminal()
    }

    func equalizeGroups() {
        tabGroups.ratios = [:]
        persist()
    }

    func setGroupRatio(_ ratio: Double, path: String, save: Bool) {
        tabGroups.ratios[path] = min(0.9, max(0.1, ratio))
        if save { persist() }
    }

    func requestCloseGroup(_ id: UUID) {
        guard let group = tabGroups.groups.first(where: { $0.id == id }) else { return }
        if tabs.contains(where: { group.tabIDs.contains($0.id) && $0.requiresCloseConfirmation }) {
            groupPendingClosure = id
        } else { closeGroup(id) }
    }

    func closeGroup(_ id: UUID) {
        guard let group = tabGroups.groups.first(where: { $0.id == id }) else { return }
        tabs.filter { group.tabIDs.contains($0.id) }.forEach { $0.disconnectAll() }
        tabs.removeAll { group.tabIDs.contains($0.id) }
        if tabGroups.groups.count == 1 { tabGroups = TabGroupWorkspace() }
        else { tabGroups.removeGroup(id) }
        groupPendingClosure = nil
        activateGroup(tabGroups.activeGroupID)
    }

    func splitPane(in tabID: WorkspaceTab.ID, axis: PaneSplitAxis) {
        selectTab(tabID)
        createGroup(axis == .vertical ? .right : .down, moving: tabID)
    }

    func focusPane(_ paneID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.layout.contains(paneID) }) else { return }
        guard tabs[tabIndex].selectedPaneID != paneID || selectedTabID != tabs[tabIndex].id else { return }
        selectedTab?.controller.hostedTerminal().dismissSearch()
        tabs[tabIndex].selectedPaneID = paneID
        selectedTabID = tabs[tabIndex].id
        selectedProfileID = tabs[tabIndex].controller.profile.id
        resetFindSummary()
        if findBarVisible, !findQuery.isEmpty {
            performFind(forward: true)
        }
        persist()
    }

    func selectRelativePane(_ delta: Int) {
        guard delta != 0,
              let tabIndex = tabs.firstIndex(where: { $0.id == selectedTabID })
        else { return }
        let paneIDs = tabs[tabIndex].layout.paneIDs
        guard paneIDs.count > 1,
              let currentIndex = paneIDs.firstIndex(of: tabs[tabIndex].selectedPaneID)
        else { return }
        let nextIndex = (currentIndex + delta + paneIDs.count) % paneIDs.count
        let nextPaneID = paneIDs[nextIndex]
        focusPane(nextPaneID)
        DispatchQueue.main.async { [weak self] in
            self?.selectedTab?.controller.focusTerminal()
        }
    }

    func requestCloseSelectedPane() {
        guard let tabID = selectedTabID else { return }
        requestClosePane(in: tabID)
    }

    func requestClosePane(in tabID: WorkspaceTab.ID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        guard tab.paneCount > 1 else {
            requestCloseTab(tabID)
            return
        }
        let controller = tab.controller
        guard controller.state.requiresCloseConfirmation else {
            closePane(tabID: tabID, paneID: tab.selectedPaneID)
            return
        }
        panePendingClosure = PaneCloseRequest(
            tabID: tabID,
            paneID: tab.selectedPaneID,
            title: controller.title
        )
    }

    func confirmClosePane(_ request: PaneCloseRequest) {
        panePendingClosure = nil
        closePane(tabID: request.tabID, paneID: request.paneID)
    }

    func cancelClosePane() {
        panePendingClosure = nil
    }

    func controller(in tabID: WorkspaceTab.ID, paneID: UUID) -> ConnectionController? {
        tabs.first(where: { $0.id == tabID })?.controller(for: paneID)
    }

    func isSelectedPane(tabID: WorkspaceTab.ID, paneID: UUID) -> Bool {
        selectedTabID == tabID && selectedTab?.selectedPaneID == paneID
    }

    func disconnectSelectedTab() {
        selectedTab?.controller.disconnect()
    }

    func clearSelectedTerminal() {
        guard let terminal = selectedTab?.controller.hostedTerminal() else { return }
        terminal.clearScreenAndScrollback()
        resetFindSummary()
    }

    func performFind(forward: Bool) {
        guard let terminal = selectedTab?.controller.hostedTerminal() else {
            resetFindSummary()
            return
        }
        guard !findQuery.isEmpty else {
            terminal.dismissSearch()
            resetFindSummary()
            return
        }
        if forward {
            _ = terminal.findForward(findQuery, caseSensitive: findCaseSensitive)
        } else {
            _ = terminal.findBackward(findQuery, caseSensitive: findCaseSensitive)
        }
        let summary = terminal.searchSummary(findQuery, caseSensitive: findCaseSensitive)
        findMatchIndex = summary.index
        findMatchTotal = summary.total
    }

    func dismissFind() {
        findBarVisible = false
        selectedTab?.controller.hostedTerminal().dismissSearch()
        resetFindSummary()
    }

    func selectRelativeTab(_ delta: Int) {
        guard let ids = tabGroups.activeGroup?.tabIDs, !ids.isEmpty,
              let id = selectedTabID, let index = ids.firstIndex(of: id) else { return }
        selectTab(ids[(index + delta + ids.count) % ids.count])
        focusActiveTerminal()
    }

    private func closePane(tabID: WorkspaceTab.ID, paneID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[tabIndex].paneCount > 1,
              let controller = tabs[tabIndex].controller(for: paneID),
              let layout = tabs[tabIndex].layout.removing(paneID)
        else { return }

        let paneIDs = tabs[tabIndex].layout.paneIDs
        let removedIndex = paneIDs.firstIndex(of: paneID) ?? 0
        let remainingPaneIDs = layout.paneIDs
        let fallbackIndex = min(removedIndex, remainingPaneIDs.count - 1)
        let selectedPaneID = remainingPaneIDs[fallbackIndex]

        controller.disconnect()
        tabs[tabIndex].controllers.removeValue(forKey: paneID)
        tabs[tabIndex].layout = layout
        tabs[tabIndex].selectedPaneID = selectedPaneID
        selectedTabID = tabID
        selectedProfileID = tabs[tabIndex].controller.profile.id
        resetFindSummary()
        persist()
        DispatchQueue.main.async { [weak self] in
            self?.selectedTab?.controller.focusTerminal()
        }
    }

    private func updateProfile(_ id: SessionProfile.ID, mutation: (inout SessionProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        mutation(&profiles[index])
        synchronizeOpenTabs(with: profiles[index])
        persist()
    }

    private func resetFindSummary() {
        findMatchIndex = 0
        findMatchTotal = 0
    }

    private func addSessionGroupIfNeeded(_ groupName: String) {
        guard !groupName.isEmpty,
              !sessionGroups.contains(where: {
                  $0.localizedCaseInsensitiveCompare(groupName) == .orderedSame
              })
        else { return }
        sessionGroups.append(groupName)
    }

    private func normalizedSessionGroupNames(_ groupNames: [String]) -> [String] {
        var result: [String] = []
        for rawName in groupNames {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !result.contains(where: {
                      $0.localizedCaseInsensitiveCompare(name) == .orderedSame
                  })
            else { continue }
            result.append(name)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func synchronizeOpenTabs(with profile: SessionProfile) {
        for index in tabs.indices {
            for paneID in tabs[index].layout.paneIDs
            where tabs[index].controller(for: paneID)?.profile.id == profile.id {
                tabs[index].controller(for: paneID)?.profile = profile
            }
        }
    }

    private func restoredTab(from snapshot: WorkspaceTabSnapshot) -> WorkspaceTab? {
        var controllers: [UUID: ConnectionController] = [:]
        for pane in snapshot.panes {
            guard controllers[pane.id] == nil,
                  let profile = profiles.first(where: { $0.id == pane.sessionID })
            else { continue }
            controllers[pane.id] = ConnectionController(id: pane.id, profile: profile, model: self)
        }

        let availablePaneIDs = Set(controllers.keys)
        guard let layout = snapshot.layout.retaining(availablePaneIDs),
              let fallbackPaneID = layout.paneIDs.first
        else { return nil }
        let selectedPaneID = layout.contains(snapshot.selectedPaneID)
            ? snapshot.selectedPaneID
            : fallbackPaneID
        return WorkspaceTab(
            layout: layout,
            controllers: controllers,
            selectedPaneID: selectedPaneID
        )
    }

    @discardableResult
    private func markSessionUsed(_ id: SessionProfile.ID) -> SessionProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        profiles[index].lastUsedAt = Date()
        synchronizeOpenTabs(with: profiles[index])
        persist()
        return profiles[index]
    }

    private func shellArgument(_ value: String) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@:%+"))
        if value.unicodeScalars.allSatisfy(safeCharacters.contains) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    func promptHostKey(_ check: HostKeyCheck) async -> HostKeyDecision {
        let request = HostKeyPromptState(check: check)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancel); return }
                if let existing = hostKeyContinuation {
                    hostKeyContinuation = nil
                    existing.resume(returning: .cancel)
                }
                hostKeyContinuation = continuation
                hostKeyPrompt = request
            }
        } onCancel: {
            Task { @MainActor in
                if self.hostKeyPrompt?.id == request.id { self.resolveHostKey(.cancel) }
            }
        }
    }

    func resolveHostKey(_ decision: HostKeyDecision) {
        hostKeyPrompt = nil
        guard let continuation = hostKeyContinuation else { return }
        hostKeyContinuation = nil
        Task { @MainActor in
            continuation.resume(returning: decision)
        }
    }
}

@MainActor
@Observable
final class ConnectionController: Identifiable {
    let id: UUID
    var profile: SessionProfile
    var state: SSHConnectionState = .disconnected
    var cols = 80
    var rows = 24
    var lastError: String?
    var remoteTitle: String?
    var portForwardStatuses: [PortForwardStatus]

    private weak var model: AppModel?
    private var session: CitadelSSHSession?
    private var connectTask: Task<Void, Never>?
    @ObservationIgnored
    private let outbound = SSHOutbound()
    @ObservationIgnored
    private let inbound = TerminalInbound()
    @ObservationIgnored
    private var hostedView: SSHTerminalView?

    init(id: UUID = UUID(), profile: SessionProfile, model: AppModel) {
        self.id = id
        self.profile = profile
        self.model = model
        self.portForwardStatuses = profile.portForwards.map { PortForwardStatus(rule: $0, state: .stopped) }
    }

    func hostedTerminal() -> SSHTerminalView {
        if let hostedView { return hostedView }
        let view = SSHTerminalView(
            typography: model?.typography ?? .default,
            colorSchemeID: model?.colorSchemeID ?? .dark,
            scrollback: model?.scrollback ?? .default
        )
        view.onSend = { [outbound] data in
            outbound.send(data)
        }
        view.onSizeChanged = { [weak self] cols, rows in
            Task { @MainActor in
                self?.noteSize(cols: cols, rows: rows)
            }
        }
        view.onTitleChanged = { [weak self] rawTitle in
            Task { @MainActor in
                self?.remoteTitle = TerminalTitlePolicy.displayTitle(from: rawTitle)
            }
        }
        hostedView = view
        inbound.attach(view)
        return view
    }

    func applyScrollback(_ scrollback: TerminalScrollback) {
        hostedView?.applyScrollback(scrollback)
    }

    func focusTerminal() {
        guard let hostedView, let window = hostedView.window else { return }
        window.makeFirstResponder(hostedView)
    }

    func noteFocus() {
        model?.focusPane(id)
    }

    var title: String { remoteTitle ?? profile.displayName }

    var canReuseForConnection: Bool {
        switch state {
        case .disconnected, .failed:
            true
        case .connecting, .connected:
            false
        }
    }

    var canDisconnect: Bool {
        switch state {
        case .connecting, .connected:
            true
        case .disconnected, .failed:
            false
        }
    }

    var canReconnect: Bool {
        if case .connecting = state {
            false
        } else {
            true
        }
    }

    var statusText: String {
        switch state {
        case .disconnected: String(localized: "Disconnected")
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .failed(let error): error.userMessage
        }
    }

    func connect() {
        _ = hostedTerminal()
        connectTask?.cancel()
        connectTask = Task { await runConnect() }
    }

    func disconnect() {
        connectTask?.cancel()
        let previous = session
        session = nil
        outbound.attach(nil)
        state = .disconnected
        portForwardStatuses = portForwardStatuses.map {
            var value = $0; value.state = .stopped; value.connections = 0; return value
        }
        Task { await previous?.disconnect() }
    }

    func noteSize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        Task { try? await session?.resize(cols: cols, rows: rows) }
    }

    func startPortForward(_ id: UUID) { Task { await session?.startPortForward(id) } }
    func stopPortForward(_ id: UUID) { Task { await session?.stopPortForward(id) } }

    private func runConnect() async {
        lastError = nil
        state = .connecting
        outbound.attach(nil)
        let route: [SSHConnectionHop]
        do {
            guard let model else { throw SSHError.connectionFailed }
            route = try model.prepareConnectionRoute(for: profile)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled { return }
            state = .failed((error as? SSHError) ?? .invalidJumpRoute)
            lastError = (error as? SSHError)?.userMessage ?? error.localizedDescription
            return
        }
        let store = model?.hostKeyStore ?? HostKeyStore(fileURL: URL(fileURLWithPath: "/tmp/termeow-host-keys.json"))
        let bridge = HostKeyBridge(model: model)
        let ssh = CitadelSSHSession(
            profile: profile, secret: route.last?.secret ?? "", hostKeyStore: store,
            jumpHosts: Array(route.dropLast())
        ) { check in
            await bridge.prompt(check)
        }
        session = ssh
        portForwardStatuses = profile.portForwards.map { PortForwardStatus(rule: $0, state: .stopped) }
        ssh.onPortForwardChange = { [weak self, weak ssh] statuses in
            Task { @MainActor in
                guard let self, let ssh, self.session === ssh else { return }
                self.portForwardStatuses = statuses
            }
        }
        ssh.onOutput = { [inbound] data in
            inbound.feed(data)
        }
        ssh.onStateChange = { [weak self, weak ssh] newState in
            Task { @MainActor in
                guard let self, let ssh, self.session === ssh else { return }
                self.applySessionState(newState, from: ssh)
            }
        }
        do {
            try await ssh.connect()
            guard session === ssh else {
                await ssh.disconnect()
                return
            }
            applySessionState(ssh.state, from: ssh)
            if ssh.state == .connected {
                try? await ssh.resize(cols: cols, rows: rows)
            }
        } catch {
            ssh.onOutput = nil
            guard session === ssh else { return }
            if Task.isCancelled || error is CancellationError {
                await ssh.disconnect()
                state = .disconnected
                return
            }
            let mapped = (error as? SSHError) ?? .connectionFailed
            state = .failed(mapped)
            lastError = mapped.userMessage
            AppLog.ssh.error("Connect failed")
        }
    }

    private func applySessionState(_ newState: SSHConnectionState, from ssh: CitadelSSHSession) {
        state = newState
        switch newState {
        case .connected:
            outbound.attach(ssh)
        case .failed(let error):
            outbound.attach(nil)
            lastError = error.userMessage
        case .disconnected:
            outbound.attach(nil)
        case .connecting:
            break
        }
    }
}

final class SSHOutbound: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var session: CitadelSSHSession?

    init() {
        let pair = AsyncStream<Data>.makeStream()
        continuation = pair.continuation
        Task.detached(priority: .userInitiated) { [stream = pair.stream, weak self] in
            for await data in stream {
                guard let session = self?.currentSession() else { continue }
                try? await session.send(data)
            }
        }
    }

    func attach(_ session: CitadelSSHSession?) {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func send(_ data: Data) {
        continuation.yield(data)
    }

    private func currentSession() -> CitadelSSHSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
}

@MainActor
struct WorkspaceTab: Identifiable {
    let id: UUID
    var layout: PaneLayout
    var controllers: [UUID: ConnectionController]
    var selectedPaneID: UUID

    init(
        id: UUID = UUID(),
        layout: PaneLayout,
        controllers: [UUID: ConnectionController],
        selectedPaneID: UUID
    ) {
        precondition(layout.contains(selectedPaneID))
        precondition(Set(layout.paneIDs).isSubset(of: Set(controllers.keys)))
        self.id = id
        self.layout = layout
        self.controllers = controllers
        self.selectedPaneID = selectedPaneID
    }

    init(id: UUID = UUID(), controller: ConnectionController) {
        self.init(
            id: id,
            layout: .leaf(controller.id),
            controllers: [controller.id: controller],
            selectedPaneID: controller.id
        )
    }

    var controller: ConnectionController {
        guard let controller = controllers[selectedPaneID] else {
            preconditionFailure("A workspace tab must have a controller for its selected pane")
        }
        return controller
    }

    var allControllers: [ConnectionController] {
        layout.paneIDs.compactMap { controllers[$0] }
    }

    var paneCount: Int { layout.paneIDs.count }
    var sessionID: UUID { controller.profile.id }
    var state: SSHConnectionState {
        aggregateState(allControllers.map(\.state)) ?? .disconnected
    }
    var requiresCloseConfirmation: Bool {
        allControllers.contains { $0.state.requiresCloseConfirmation }
    }

    var snapshot: WorkspaceTabSnapshot {
        WorkspaceTabSnapshot(
            layout: layout,
            panes: layout.paneIDs.compactMap { paneID in
                controllers[paneID].map {
                    WorkspacePaneSnapshot(id: paneID, sessionID: $0.profile.id)
                }
            },
            selectedPaneID: selectedPaneID
        )
    }

    func controller(for paneID: UUID) -> ConnectionController? {
        controllers[paneID]
    }

    func contains(profileID: UUID) -> Bool {
        allControllers.contains { $0.profile.id == profileID }
    }

    func connectionState(for profileID: UUID) -> SSHConnectionState? {
        aggregateState(
            allControllers.lazy
                .filter { $0.profile.id == profileID }
                .map(\.state)
        )
    }

    func disconnectAll() {
        allControllers.forEach { $0.disconnect() }
    }

    mutating func replaceController(_ controller: ConnectionController, for paneID: UUID) {
        precondition(layout.contains(paneID))
        precondition(controller.id == paneID)
        controllers[paneID] = controller
    }

    private func aggregateState<S: Sequence>(_ states: S) -> SSHConnectionState? where S.Element == SSHConnectionState {
        let states = Array(states)
        guard !states.isEmpty else { return nil }
        if states.contains(.connected) { return .connected }
        if states.contains(.connecting) { return .connecting }
        if let failed = states.first(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            return failed
        }
        return .disconnected
    }
}

struct TabCloseRequest: Identifiable {
    let id: WorkspaceTab.ID
    let title: String
    var extraIDs: [UUID] = []
}

struct PaneCloseRequest: Identifiable {
    var id: UUID { paneID }
    let tabID: WorkspaceTab.ID
    let paneID: UUID
    let title: String
}

struct SessionEditorState: Identifiable {
    var id: UUID { profile.id }
    var profile: SessionProfile
    var secret: String
}

struct HostKeyPromptState: Identifiable {
    let id = UUID()
    var check: HostKeyCheck
}

final class HostKeyBridge: @unchecked Sendable {
    @MainActor weak var model: AppModel?

    @MainActor
    init(model: AppModel?) {
        self.model = model
    }

    func prompt(_ check: HostKeyCheck) async -> HostKeyDecision {
        await promptOnMain(check)
    }

    @MainActor
    private func promptOnMain(_ check: HostKeyCheck) async -> HostKeyDecision {
        await model?.promptHostKey(check) ?? .cancel
    }
}
