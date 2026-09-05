import AppKit
import Observation
import SwiftUI
import TermeowKit

@MainActor
@Observable
final class AppModel {
    var profiles: [SessionProfile] = []
    var tabs: [WorkspaceTab] = []
    var selectedProfileID: SessionProfile.ID?
    var selectedTabID: WorkspaceTab.ID?
    var searchText = ""
    var editor: SessionEditorState?
    var hostKeyPrompt: HostKeyPromptState?
    @ObservationIgnored
    private var hostKeyContinuation: CheckedContinuation<HostKeyDecision, Never>?
    var findBarVisible = false
    var findQuery = ""
    var findCaseSensitive = false
    var sidebarVisible = true
    var statusMessage: String?

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

    var filteredProfiles: [SessionProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.host.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
                || $0.groupName.localizedCaseInsensitiveContains(query)
        }
    }

    var groupedProfiles: [(name: String, profiles: [SessionProfile])] {
        let grouped = Dictionary(grouping: filteredProfiles) { $0.groupName.isEmpty ? "Sessions" : $0.groupName }
        return grouped.keys.sorted().map { name in
            (name, grouped[name]!.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending })
        }
    }

    func reload() {
        do {
            profiles = try sessionStore.load()
        } catch {
            AppLog.storage.error("Failed to load sessions")
            profiles = []
        }
        let snapshot = (try? workspaceStore.load()) ?? WorkspaceSnapshot()
        selectedProfileID = snapshot.selectedProfileID ?? profiles.first?.id
        for sessionID in snapshot.openSessionIDs {
            if let profile = profiles.first(where: { $0.id == sessionID }) {
                openTab(for: profile, connect: false)
            }
        }
        if selectedTabID == nil {
            selectedTabID = tabs.first?.id
        }
    }

    func persist() {
        do {
            try sessionStore.save(profiles)
            try workspaceStore.save(
                WorkspaceSnapshot(
                    openSessionIDs: tabs.map(\.sessionID),
                    selectedProfileID: selectedProfileID
                )
            )
        } catch {
            AppLog.storage.error("Failed to persist sessions")
        }
    }

    func beginNewSession() {
        editor = SessionEditorState(profile: SessionProfile(name: "New Session", host: "", username: ""), secret: "")
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
        copy.name = profile.name.isEmpty ? "\(profile.displayName) copy" : "\(profile.name) copy"
        if let secret = try? keychain.secret(id: profile.credentialID) {
            try? keychain.saveSecret(secret, id: copy.credentialID)
        }
        profiles.append(copy)
        selectedProfileID = copy.id
        persist()
    }

    func deleteSelected() {
        guard let id = selectedProfileID else { return }
        if let profile = profiles.first(where: { $0.id == id }) {
            try? keychain.deleteSecret(id: profile.credentialID)
        }
        profiles.removeAll { $0.id == id }
        tabs.removeAll { $0.sessionID == id }
        selectedProfileID = profiles.first?.id
        selectedTabID = tabs.first?.id
        persist()
    }

    func saveEditor() {
        guard var state = editor else { return }
        if state.profile.name.isEmpty {
            state.profile.name = state.profile.displayName
        }
        if let index = profiles.firstIndex(where: { $0.id == state.profile.id }) {
            profiles[index] = state.profile
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
        if let existing = tabs.first(where: { $0.sessionID == profile.id }) {
            selectedTabID = existing.id
            existing.controller.connect()
            return
        }
        openTab(for: profile, connect: true)
    }

    func openSelectedInNewTab() {
        guard let profile = selectedProfile else { return }
        openTab(for: profile, connect: true)
    }

    func openTab(for profile: SessionProfile, connect: Bool) {
        let tab = WorkspaceTab(sessionID: profile.id, controller: ConnectionController(profile: profile, model: self))
        tabs.append(tab)
        selectedTabID = tab.id
        persist()
        if connect {
            tab.controller.connect()
        }
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

    func disconnectSelectedTab() {
        selectedTab?.controller.disconnect()
    }

    func selectRelativeTab(_ delta: Int) {
        guard let id = selectedTabID, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let next = (index + delta + tabs.count) % max(tabs.count, 1)
        selectedTabID = tabs[next].id
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
    let engine = TerminalEngine()
    var state: SSHConnectionState = .disconnected
    var cols = 80
    var rows = 24
    var lastError: String?
    var layout: PaneLayout = .leaf

    private weak var model: AppModel?
    private var session: CitadelSSHSession?
    private var outputTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    init(profile: SessionProfile, model: AppModel) {
        self.profile = profile
        self.model = model
        engine.onSend = { [weak self] data in
            Task { @MainActor in
                try? await self?.session?.send(data)
            }
        }
    }

    var title: String { profile.displayName }

    var statusText: String {
        switch state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed(let error): error.userMessage
        }
    }

    func connect() {
        connectTask?.cancel()
        connectTask = Task { await runConnect() }
    }

    func disconnect() {
        connectTask?.cancel()
        outputTask?.cancel()
        Task {
            await session?.disconnect()
            session = nil
            state = .disconnected
        }
    }

    func sendRemoteOnly(_ data: Data) {
        Task { try? await session?.send(data) }
    }

    func noteSize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        Task { try? await session?.resize(cols: cols, rows: rows) }
    }

    private func runConnect() async {
        lastError = nil
        state = .connecting
        let secret = (try? model?.keychain.secret(id: profile.credentialID)) ?? ""
        let store = model?.hostKeyStore ?? HostKeyStore(fileURL: URL(fileURLWithPath: "/tmp/termeow-host-keys.json"))
        let bridge = HostKeyBridge(model: model)
        let ssh = CitadelSSHSession(profile: profile, secret: secret, hostKeyStore: store) { check in
            await bridge.prompt(check)
        }
        session = ssh
        do {
            try await ssh.connect()
            state = .connected
            outputTask?.cancel()
            let output = ssh.output
            outputTask = Task.detached { [engine] in
                for await data in output {
                    engine.feed(data)
                }
            }
            try? await ssh.resize(cols: cols, rows: rows)
        } catch {
            let mapped = (error as? SSHError) ?? .connectionFailed
            state = .failed(mapped)
            lastError = mapped.userMessage
            AppLog.ssh.error("Connect failed")
        }
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

struct WorkspaceSnapshot: Codable, Equatable {
    var openSessionIDs: [UUID] = []
    var selectedProfileID: UUID?
}

struct WorkspaceStore: Sendable {
    var fileURL: URL

    static func defaultURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("cn.termeow.Termeow", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("workspace.json")
    }

    func load() throws -> WorkspaceSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return WorkspaceSnapshot() }
        return try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: fileURL))
    }

    func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
