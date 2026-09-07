import AppKit
import SwiftUI
import TermeowKit

private enum SessionSortOrder: String, CaseIterable, Identifiable {
    case name
    case host
    case recent

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .name: "Name"
        case .host: "Host"
        case .recent: "Last Used"
        }
    }
}

private struct SessionListSection: Identifiable {
    enum Kind {
        case favorites
        case ungrouped
        case group(String)

        var groupName: String? {
            if case .group(let name) = self { return name }
            return nil
        }
    }

    let id: String
    let title: String
    let systemImage: String
    let profiles: [SessionProfile]
    let kind: Kind
}

private enum SessionSidebarPrompt {
    case renameSession(SessionProfile)
    case moveToNewGroup(SessionProfile)
    case createGroup
    case renameGroup(String)
    case deleteGroup(String)

    var title: LocalizedStringKey {
        switch self {
        case .renameSession: "Rename Session"
        case .moveToNewGroup, .createGroup: "New Group"
        case .renameGroup: "Rename Group"
        case .deleteGroup: "Delete Group"
        }
    }
}

private struct SessionSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Sessions", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }
}

struct SessionSidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sessionSortOrder") private var sortOrderRawValue = SessionSortOrder.name.rawValue
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var renameDraft = ""
    @State private var groupDraft = ""
    @State private var newGroupDraft = ""
    @State private var groupRenameDraft = ""
    @State private var activePrompt: SessionSidebarPrompt?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SessionSearchField(text: $model.searchText)
            Divider()
            List(selection: $model.selectedProfileID) {
                ForEach(sections) { section in
                    SessionSectionView(
                        section: section,
                        isExpanded: expansionBinding(for: section.id),
                        onRename: beginRenaming,
                        onNewGroup: beginGrouping,
                        onCreateSession: { model.beginNewSession(inGroup: $0) },
                        onCreateGroup: beginCreatingGroup,
                        onRenameGroup: beginRenamingGroup,
                        onDeleteGroup: { activePrompt = .deleteGroup($0) }
                    )
                }
            }
            .listStyle(.sidebar)
            .tint(.blue)
            .contextMenu { sidebarContextMenu }
            .overlay { emptyState }
        }
        .navigationTitle("Sessions")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(sessionCountText)
                Spacer()
                if model.selectedProfile != nil {
                    Button("Connect", systemImage: "play.fill") {
                        model.connectSelected()
                    }
                    .buttonStyle(.borderless)
                    .help("Connect")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .onKeyPress(.return) {
            guard model.selectedProfile != nil else { return .ignored }
            model.connectSelected()
            return .handled
        }
        .onDeleteCommand {
            model.deleteSelected()
        }
        .alert(activePrompt?.title ?? "", isPresented: promptPresented, presenting: activePrompt) { prompt in
            promptActions(for: prompt)
        } message: { prompt in
            promptMessage(for: prompt)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    creationMenu
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add Session or Group")
                Menu {
                    listOptionsMenu
                } label: {
                    Label("Session List Options", systemImage: "ellipsis.circle")
                }
                .help("Session List Options")
            }
        }
    }

    private var sortOrder: SessionSortOrder {
        SessionSortOrder(rawValue: sortOrderRawValue) ?? .name
    }

    private var sections: [SessionListSection] {
        var result: [SessionListSection] = []
        let favorites = sorted(model.filteredProfiles.filter(\.isFavorite))
        if !favorites.isEmpty {
            result.append(
                SessionListSection(
                    id: "favorites",
                    title: String(localized: "Favorites"),
                    systemImage: "star.fill",
                    profiles: favorites,
                    kind: .favorites
                )
            )
        }

        let regularProfiles = model.filteredProfiles.filter { !$0.isFavorite }
        let ungrouped = sorted(regularProfiles.filter { $0.groupName.isEmpty })
        let isFiltering = !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !ungrouped.isEmpty || (!isFiltering && (!model.profiles.isEmpty || !model.sessionGroupNames.isEmpty)) {
            result.append(
                SessionListSection(
                    id: "ungrouped",
                    title: String(localized: "Sessions"),
                    systemImage: "rectangle.stack",
                    profiles: ungrouped,
                    kind: .ungrouped
                )
            )
        }

        let visibleGroupNames = isFiltering
            ? model.sessionGroupNames.filter { groupName in
                regularProfiles.contains {
                    $0.groupName.localizedCaseInsensitiveCompare(groupName) == .orderedSame
                }
            }
            : model.sessionGroupNames
        for groupName in visibleGroupNames {
            result.append(
                SessionListSection(
                    id: "group:\(groupName)",
                    title: groupName,
                    systemImage: "folder",
                    profiles: sorted(regularProfiles.filter {
                        $0.groupName.localizedCaseInsensitiveCompare(groupName) == .orderedSame
                    }),
                    kind: .group(groupName)
                )
            )
        }
        return result
    }

    private func sorted(_ profiles: [SessionProfile]) -> [SessionProfile] {
        profiles.sorted { lhs, rhs in
            switch sortOrder {
            case .name:
                localizedAscending(lhs.displayName, rhs.displayName)
            case .host:
                if lhs.host.localizedStandardCompare(rhs.host) != .orderedSame {
                    localizedAscending(lhs.host, rhs.host)
                } else if lhs.port != rhs.port {
                    lhs.port < rhs.port
                } else {
                    localizedAscending(lhs.displayName, rhs.displayName)
                }
            case .recent:
                if lhs.lastUsedAt != rhs.lastUsedAt {
                    (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
                } else {
                    localizedAscending(lhs.displayName, rhs.displayName)
                }
            }
        }
    }

    private func localizedAscending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func expansionBinding(for sectionID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSectionIDs.contains(sectionID) },
            set: { isExpanded in
                if isExpanded {
                    collapsedSectionIDs.remove(sectionID)
                } else {
                    collapsedSectionIDs.insert(sectionID)
                }
            }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if sections.isEmpty {
            if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("No Sessions", systemImage: "server.rack")
                } description: {
                    Text("Create a session to connect to an SSH server.")
                } actions: {
                    Button("New Session…") { model.beginNewSession() }
                }
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }

    private var sessionCountText: String {
        let count = model.filteredProfiles.count
        if count == 1 {
            return String(localized: "1 session")
        }
        return String(format: String(localized: "%lld sessions"), Int64(count))
    }

    private var promptPresented: Binding<Bool> {
        Binding(
            get: { activePrompt != nil },
            set: { if !$0 { activePrompt = nil } }
        )
    }

    @ViewBuilder
    private func promptActions(for prompt: SessionSidebarPrompt) -> some View {
        switch prompt {
        case .renameSession(let profile):
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { activePrompt = nil }
            Button("Rename") { finishRenaming(profile) }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .moveToNewGroup(let profile):
            TextField("Group", text: $groupDraft)
            Button("Cancel", role: .cancel) { activePrompt = nil }
            Button("Move") { finishGrouping(profile) }
                .disabled(groupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .createGroup:
            TextField("Group", text: $newGroupDraft)
            Button("Cancel", role: .cancel) { activePrompt = nil }
            Button("Create") { finishCreatingGroup() }
                .disabled(!model.canUseSessionGroupName(newGroupDraft))
        case .renameGroup(let groupName):
            TextField("Group", text: $groupRenameDraft)
            Button("Cancel", role: .cancel) { activePrompt = nil }
            Button("Rename") { finishRenamingGroup(groupName) }
                .disabled(!model.canUseSessionGroupName(groupRenameDraft, excluding: groupName))
        case .deleteGroup(let groupName):
            Button("Cancel", role: .cancel) { activePrompt = nil }
            Button("Delete Group", role: .destructive) { finishDeletingGroup(groupName) }
        }
    }

    @ViewBuilder
    private func promptMessage(for prompt: SessionSidebarPrompt) -> some View {
        switch prompt {
        case .renameSession:
            Text("Enter a new name for this saved session.")
        case .moveToNewGroup:
            Text("Enter the group name for this session.")
        case .createGroup:
            Text("Enter a name for the new group.")
        case .renameGroup:
            Text("Enter a new name for this group.")
        case .deleteGroup:
            Text("Sessions in this group will be moved to Sessions.")
        }
    }

    @ViewBuilder
    private var creationMenu: some View {
        Button("New Session…", systemImage: "server.rack") {
            model.beginNewSession()
        }
        Button("New Group…", systemImage: "folder.badge.plus") {
            beginCreatingGroup()
        }
    }

    @ViewBuilder
    private var listOptionsMenu: some View {
        Picker("Sort By", selection: $sortOrderRawValue) {
            ForEach(SessionSortOrder.allCases) { order in
                Text(order.title).tag(order.rawValue)
            }
        }
        Divider()
        Button("Expand All", systemImage: "rectangle.expand.vertical") {
            collapsedSectionIDs.removeAll()
        }
        Button("Collapse All", systemImage: "rectangle.compress.vertical") {
            collapsedSectionIDs = Set(sections.map(\.id))
        }
    }

    @ViewBuilder
    private var sidebarContextMenu: some View {
        creationMenu
        Divider()
        listOptionsMenu
    }

    private func beginRenaming(_ profile: SessionProfile) {
        model.selectedProfileID = profile.id
        renameDraft = profile.displayName
        activePrompt = .renameSession(profile)
    }

    private func finishRenaming(_ profile: SessionProfile) {
        model.rename(profile, to: renameDraft)
        activePrompt = nil
    }

    private func beginGrouping(_ profile: SessionProfile) {
        model.selectedProfileID = profile.id
        groupDraft = ""
        activePrompt = .moveToNewGroup(profile)
    }

    private func finishGrouping(_ profile: SessionProfile) {
        model.move(profile, toGroup: groupDraft)
        activePrompt = nil
    }

    private func beginCreatingGroup() {
        newGroupDraft = ""
        activePrompt = .createGroup
    }

    private func finishCreatingGroup() {
        let groupName = newGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.createSessionGroup(groupName)
        collapsedSectionIDs.remove("group:\(groupName)")
        activePrompt = nil
    }

    private func beginRenamingGroup(_ groupName: String) {
        groupRenameDraft = groupName
        activePrompt = .renameGroup(groupName)
    }

    private func finishRenamingGroup(_ groupName: String) {
        let newName = groupRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.renameSessionGroup(groupName, to: newName)
        if collapsedSectionIDs.remove("group:\(groupName)") != nil {
            collapsedSectionIDs.insert("group:\(newName)")
        }
        activePrompt = nil
    }

    private func finishDeletingGroup(_ groupName: String) {
        model.deleteSessionGroup(groupName)
        collapsedSectionIDs.remove("group:\(groupName)")
        activePrompt = nil
    }
}

private struct SessionSectionView: View {
    @Environment(AppModel.self) private var model
    let section: SessionListSection
    @Binding var isExpanded: Bool
    let onRename: (SessionProfile) -> Void
    let onNewGroup: (SessionProfile) -> Void
    let onCreateSession: (String) -> Void
    let onCreateGroup: () -> Void
    let onRenameGroup: (String) -> Void
    let onDeleteGroup: (String) -> Void

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(section.profiles) { profile in
                SessionListRow(
                    profile: profile,
                    selected: model.selectedProfileID == profile.id,
                    tabStates: model.tabStates(for: profile.id),
                    onRename: { onRename(profile) },
                    onNewGroup: { onNewGroup(profile) }
                )
                .tag(profile.id)
            }
        } header: {
            header
                .contentShape(Rectangle())
                .contextMenu { sectionMenu }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: section.systemImage)
            Text(verbatim: section.title)
            Spacer()
            Text(verbatim: "\(section.profiles.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var sectionMenu: some View {
        if let groupName = section.kind.groupName {
            Button("New Session in Group…", systemImage: "server.rack") {
                onCreateSession(groupName)
            }
        } else {
            Button("New Session…", systemImage: "server.rack") {
                onCreateSession("")
            }
        }
        Button("New Group…", systemImage: "folder.badge.plus", action: onCreateGroup)
        Divider()
        if isExpanded {
            Button("Collapse Group", systemImage: "chevron.up") { isExpanded = false }
        } else {
            Button("Expand Group", systemImage: "chevron.down") { isExpanded = true }
        }
        if let groupName = section.kind.groupName {
            Divider()
            Button("Rename Group…", systemImage: "pencil") { onRenameGroup(groupName) }
            Button(role: .destructive) {
                onDeleteGroup(groupName)
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
    }
}

private struct SessionListRow: View {
    @Environment(AppModel.self) private var model
    let profile: SessionProfile
    let selected: Bool
    let tabStates: [SSHConnectionState]
    let onRename: () -> Void
    let onNewGroup: () -> Void

    var body: some View {
        SessionRow(profile: profile, selected: selected, tabStates: tabStates)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                selected ? Color.blue : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .onTapGesture {
                model.selectedProfileID = profile.id
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { model.connect(profile) }
            )
            .contextMenu { sessionMenu }
    }

    @ViewBuilder
    private var sessionMenu: some View {
        Button("Connect", systemImage: "play.fill") {
            model.connect(profile)
        }
        Button("Open SFTP", systemImage: "externaldrive.connected.to.line.below") {
            model.openSFTP(profile)
        }
        Divider()
        favoriteButton
        groupMenu
        Button("Copy SSH Command", systemImage: "doc.on.doc") {
            model.copySSHCommand(profile)
        }
        Divider()
        Button("Rename…", systemImage: "pencil", action: onRename)
        Button("Edit", systemImage: "slider.horizontal.3") {
            model.selectedProfileID = profile.id
            model.editSelected()
        }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            model.selectedProfileID = profile.id
            model.duplicateSelected()
        }
        Divider()
        Button(role: .destructive) {
            model.sessionPendingDeletion = profile
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var favoriteButton: some View {
        Button {
            model.toggleFavorite(profile)
        } label: {
            Label(
                profile.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: profile.isFavorite ? "star.slash" : "star"
            )
        }
    }

    private var groupMenu: some View {
        Menu("Move to Group", systemImage: "folder") {
            Button("Sessions") {
                model.move(profile, toGroup: "")
            }
            .disabled(profile.groupName.isEmpty)
            ForEach(model.sessionGroupNames, id: \.self) { groupName in
                Button {
                    model.move(profile, toGroup: groupName)
                } label: {
                    Text(verbatim: groupName)
                }
                .disabled(profile.groupName == groupName)
            }
            Divider()
            Button("New Group…", systemImage: "folder.badge.plus", action: onNewGroup)
        }
    }
}

struct SessionRow: View {
    let profile: SessionProfile
    let selected: Bool
    let tabStates: [SSHConnectionState]

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "server.rack")
                if !tabStates.isEmpty {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(selected ? Color.blue : Color(nsColor: .controlBackgroundColor), lineWidth: 1))
                        .offset(x: 3, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).lineLimit(1)
                Text(verbatim: "\(profile.username)@\(profile.host):\(profile.port)")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if profile.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white : Color.orange)
            }
            if tabStates.count > 1 {
                Text(verbatim: "\(tabStates.count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(selected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.14), in: Capsule())
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .help(helpText)
    }

    private var statusColor: Color {
        if tabStates.contains(.connected) {
            return .green
        }
        if tabStates.contains(.connecting) {
            return .yellow
        }
        if tabStates.contains(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            return .red
        }
        return .secondary
    }

    private var helpText: String {
        let address = "\(profile.username)@\(profile.host):\(profile.port)"
        guard !tabStates.isEmpty else { return address }
        let tabCount = tabStates.count == 1
            ? String(localized: "1 open tab")
            : String(format: String(localized: "%lld open tabs"), Int64(tabStates.count))
        return "\(address) — \(tabCount) — \(statusText)"
    }

    private var statusText: String {
        if tabStates.contains(.connected) { return String(localized: "Connected") }
        if tabStates.contains(.connecting) { return String(localized: "Connecting") }
        if tabStates.contains(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            return String(localized: "Connection Failed")
        }
        return String(localized: "Disconnected")
    }
}

struct SessionEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var state: SessionEditorState

    init(state: SessionEditorState) {
        _state = State(initialValue: state)
    }

    var body: some View {
        NavigationStack {
            SessionEditorForm(state: $state) {
                model.editor = nil
            } onSave: {
                model.editor = state
                model.saveEditor()
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

struct SessionEditorForm: View {
    @Binding var state: SessionEditorState
    var onCancel: () -> Void
    var onSave: () -> Void
    @State private var keyPath = ""

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Name", text: $state.profile.name)
                TextField("Host", text: $state.profile.host)
                TextField("Port", value: $state.profile.port, format: .number)
                if !SessionProfile.validPortRange.contains(state.profile.port) {
                    validationMessage("Port must be between 1 and 65535.")
                }
                TextField("Username", text: $state.profile.username)
            }
            Section("Authentication") {
                Picker("Method", selection: $state.profile.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                if state.profile.authMethod == .password {
                    SecureField("Password", text: $state.secret)
                } else {
                    SecureField("Passphrase", text: $state.secret)
                    LabeledContent("Private Key") {
                        Button(keyPath.isEmpty ? keyLabel : keyPath) { chooseKey() }
                    }
                }
            }
            Section {
                TextField("Startup Command", text: $state.profile.startupCommand)
                TextField("Group", text: $state.profile.groupName)
                Toggle("Favorite", isOn: $state.profile.isFavorite)
            }
            Section("Advanced") {
                TextField("TERM", text: $state.profile.term)
                TextField("Timeout", value: $state.profile.timeoutSeconds, format: .number)
                if state.profile.timeoutSeconds <= 0 {
                    validationMessage("Timeout must be at least 1 second.")
                }
                TextField("Keep Alive", value: $state.profile.keepAliveSeconds, format: .number)
                if state.profile.keepAliveSeconds < 0 {
                    validationMessage("Keep Alive must be 0 or greater.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Session")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: onSave)
                    .disabled(!state.profile.isValidForSaving)
            }
        }
    }

    private func validationMessage(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }

    private var keyLabel: String {
        state.profile.privateKeyBookmark == nil
            ? String(localized: "Choose…")
            : String(localized: "Key bookmark saved")
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose Private Key")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            state.profile.privateKeyBookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            keyPath = url.path
        } catch {
            AppLog.storage.error("Could not create key bookmark")
        }
    }
}
