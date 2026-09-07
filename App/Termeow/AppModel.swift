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
    var selectedProfileID: SessionProfile.ID?
    var selectedTabID: WorkspaceTab.ID?
    var searchText = ""
    var editor: SessionEditorState?
    var sessionPendingDeletion: SessionProfile?
    var hostKeyPrompt: HostKeyPromptState?
    @ObservationIgnored
    private var hostKeyContinuation: CheckedContinuation<HostKeyDecision, Never>?
    var findBarVisible = false
    var findQuery = ""
    var findCaseSensitive = false
    var sidebarVisible = true
    var statusMessage: String?

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
        Array(
            tabs.lazy
                .filter { $0.sessionID == profileID }
                .map(\.controller.state)
        )
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
        for (index, sessionID) in snapshot.openSessionIDs.enumerated() {
            if let profile = profiles.first(where: { $0.id == sessionID }) {
                restoredTabIDs[index] = openTab(for: profile, connect: false, persistWorkspace: false)
            }
        }
        selectedTabID = snapshot.selectedTabIndex.flatMap { restoredTabIDs[$0] } ?? tabs.first?.id
    }

    func persist() {
        do {
            try sessionStore.saveLibrary(SessionLibrary(profiles: profiles, groups: sessionGroupNames))
            try workspaceStore.save(
                WorkspaceSnapshot(
                    openSessionIDs: tabs.map(\.sessionID),
                    selectedProfileID: selectedProfileID,
                    selectedTabIndex: selectedTabID.flatMap { selectedID in
                        tabs.firstIndex { $0.id == selectedID }
                    }
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
        let secret = (try? keychain.secret(id: profile.credentialID)) ?? ""
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
        if let secret = try? keychain.secret(id: profile.credentialID) {
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
        let removedTabIDs = Set(tabs.lazy.filter { $0.sessionID == profile.id }.map(\.id))
        tabs.lazy.filter { $0.sessionID == profile.id }.forEach { $0.controller.disconnect() }
        tabs.removeAll { $0.sessionID == profile.id }
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
        }
        if let selectedTabID, removedTabIDs.contains(selectedTabID) {
            self.selectedTabID = tabs.first?.id
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
        let destination = shellArgument("\(profile.username)@\(profile.host)")
        let command = profile.port == 22
            ? "ssh \(destination)"
            : "ssh -p \(profile.port) \(destination)"
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
        if !state.secret.isEmpty {
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
        let secret = (try? keychain.secret(id: profile.credentialID)) ?? ""
        let promptCoordinator = SFTPHostKeyPromptCoordinator()
        let bridge = SFTPHostKeyBridge(coordinator: promptCoordinator)
        let service = CitadelSFTPService(
            profile: profile,
            secret: secret,
            hostKeyStore: hostKeyStore
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
            tabs[index].controller.disconnect()
            let controller = ConnectionController(profile: currentProfile, model: self)
            tabs[index].sessionID = currentProfile.id
            tabs[index].controller = controller
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
        let tab = WorkspaceTab(sessionID: profile.id, controller: ConnectionController(profile: profile, model: self))
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
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func closeSelectedTab() {
        guard let id = selectedTabID, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].controller.disconnect()
        tabs.remove(at: index)
        selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        persist()
    }

    func closeTab(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].controller.disconnect()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        persist()
    }

    func reconnectTab(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let storedProfile = tabs[index].controller.profile
        let profile = markSessionUsed(storedProfile.id) ?? storedProfile
        tabs[index].controller.disconnect()
        let controller = ConnectionController(profile: profile, model: self)
        tabs[index].sessionID = profile.id
        tabs[index].controller = controller
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
        let storedProfile = tabs[index].controller.profile
        let profile = markSessionUsed(storedProfile.id) ?? storedProfile
        let controller = ConnectionController(profile: profile, model: self)
        let duplicate = WorkspaceTab(sessionID: profile.id, controller: controller)
        tabs.insert(duplicate, at: index + 1)
        selectedProfileID = profile.id
        selectedTabID = duplicate.id
        persist()
        controller.connect()
    }

    func closeOtherTabs(keeping id: WorkspaceTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tabs.lazy.filter { $0.id != id }.forEach { $0.controller.disconnect() }
        tabs = [tab]
        selectedTabID = id
        persist()
    }

    func closeTabsToRight(of id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), index + 1 < tabs.count else { return }
        tabs[(index + 1)...].forEach { $0.controller.disconnect() }
        let removedSelectedTab = tabs[(index + 1)...].contains { $0.id == selectedTabID }
        tabs.removeSubrange((index + 1)...)
        if removedSelectedTab {
            selectedTabID = id
        }
        persist()
    }

    func hasTabsToRight(of id: WorkspaceTab.ID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return index + 1 < tabs.count
    }

    func disconnectSelectedTab() {
        selectedTab?.controller.disconnect()
    }

    func selectRelativeTab(_ delta: Int) {
        guard let id = selectedTabID, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let next = (index + delta + tabs.count) % max(tabs.count, 1)
        selectedTabID = tabs[next].id
        persist()
    }

    private func updateProfile(_ id: SessionProfile.ID, mutation: (inout SessionProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        mutation(&profiles[index])
        synchronizeOpenTabs(with: profiles[index])
        persist()
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
        for index in tabs.indices where tabs[index].sessionID == profile.id {
            tabs[index].controller.profile = profile
        }
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
        await withCheckedContinuation { continuation in
            if let existing = hostKeyContinuation {
                hostKeyContinuation = nil
                existing.resume(returning: .cancel)
            }
            hostKeyContinuation = continuation
            hostKeyPrompt = HostKeyPromptState(check: check)
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
final class ConnectionController {
    let id = UUID()
    var profile: SessionProfile
    var state: SSHConnectionState = .disconnected
    var cols = 80
    var rows = 24
    var lastError: String?
    var layout: PaneLayout = .leaf

    private weak var model: AppModel?
    private var session: CitadelSSHSession?
    private var connectTask: Task<Void, Never>?
    @ObservationIgnored
    private let outbound = SSHOutbound()
    @ObservationIgnored
    private let inbound = TerminalInbound()
    @ObservationIgnored
    private var hostedView: SSHTerminalView?

    init(profile: SessionProfile, model: AppModel) {
        self.profile = profile
        self.model = model
    }

    func hostedTerminal() -> SSHTerminalView {
        if let hostedView { return hostedView }
        let view = SSHTerminalView()
        view.onSend = { [outbound] data in
            outbound.send(data)
        }
        view.onSizeChanged = { [weak self] cols, rows in
            Task { @MainActor in
                self?.noteSize(cols: cols, rows: rows)
            }
        }
        hostedView = view
        inbound.attach(view)
        return view
    }

    var title: String { profile.displayName }

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
        Task {
            outbound.attach(nil)
            await session?.disconnect()
            session = nil
            state = .disconnected
        }
    }

    func noteSize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        Task { try? await session?.resize(cols: cols, rows: rows) }
    }

    private func runConnect() async {
        lastError = nil
        state = .connecting
        outbound.attach(nil)
        let secret = (try? model?.keychain.secret(id: profile.credentialID)) ?? ""
        let store = model?.hostKeyStore ?? HostKeyStore(fileURL: URL(fileURLWithPath: "/tmp/termeow-host-keys.json"))
        let bridge = HostKeyBridge(model: model)
        let ssh = CitadelSSHSession(profile: profile, secret: secret, hostKeyStore: store) { check in
            await bridge.prompt(check)
        }
        session = ssh
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

struct WorkspaceTab: Identifiable {
    let id = UUID()
    var sessionID: UUID
    var controller: ConnectionController
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
