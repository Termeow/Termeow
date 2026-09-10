import AppKit
import SwiftUI
import TermeowKit

private enum SessionSortOrder: String, CaseIterable, Identifiable {
    case manual
    case name
    case host
    case recent

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .manual: "Manual"
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

        var snapshotKind: SessionSectionSnapshot.Kind {
            switch self {
            case .favorites: .favorites
            case .ungrouped: .ungrouped
            case .group(let name): .group(name)
            }
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
            NativeSessionList(snapshot: listSnapshot, actions: listActions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand(perform: moveSelection)
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

    private var isFiltering: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sections: [SessionListSection] {
        var result: [SessionListSection] = []
        let favorites = sorted(model.filteredProfiles.filter(\.isFavorite))
        if !favorites.isEmpty || (!isFiltering && !model.profiles.isEmpty) {
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
        if sortOrder == .manual { return profiles }
        return profiles.sorted { lhs, rhs in
            switch sortOrder {
            case .manual:
                true
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

    private var listSnapshot: SessionListSnapshot {
        SessionListSnapshot(
            sections: sections.map { section in
                SessionSectionSnapshot(
                    id: section.id,
                    title: section.title,
                    systemImage: section.systemImage,
                    kind: section.kind.snapshotKind,
                    isExpanded: !collapsedSectionIDs.contains(section.id),
                    rows: section.profiles.map { profile in
                        SessionRowSnapshot(
                            id: profile.id,
                            name: profile.displayName,
                            address: "\(profile.username)@\(profile.host):\(profile.port)",
                            isFavorite: profile.isFavorite,
                            groupName: profile.groupName,
                            tabStates: model.tabStates(for: profile.id)
                        )
                    }
                )
            },
            selectedID: model.selectedProfileID,
            allowsDrag: !isFiltering,
            groupNames: model.sessionGroupNames,
            sortOrderRaw: sortOrderRawValue
        )
    }

    private var listActions: SessionListActions {
        SessionListActions(
            onSelect: { model.selectedProfileID = $0 },
            onConnect: { id in
                if let profile = profile(id) { model.connect(profile) }
            },
            onToggleExpanded: { id in
                if collapsedSectionIDs.contains(id) {
                    collapsedSectionIDs.remove(id)
                } else {
                    collapsedSectionIDs.insert(id)
                }
            },
            onMove: applySessionDrop,
            onOpenSFTP: { id in
                if let profile = profile(id) { model.openSFTP(profile) }
            },
            onToggleFavorite: { id in
                if let profile = profile(id) { model.toggleFavorite(profile) }
            },
            onMoveToGroup: { id, group in
                if let profile = profile(id) { model.move(profile, toGroup: group) }
            },
            onNewGroupForSession: { id in
                if let profile = profile(id) { beginGrouping(profile) }
            },
            onCopySSH: { id in
                if let profile = profile(id) { model.copySSHCommand(profile) }
            },
            onRename: { id in
                if let profile = profile(id) { beginRenaming(profile) }
            },
            onEdit: { id in
                model.selectedProfileID = id
                model.editSelected()
            },
            onDuplicate: { id in
                model.selectedProfileID = id
                model.duplicateSelected()
            },
            onDelete: { id in
                if let profile = profile(id) { model.sessionPendingDeletion = profile }
            },
            onCreateSession: { model.beginNewSession(inGroup: $0) },
            onCreateGroup: beginCreatingGroup,
            onRenameGroup: beginRenamingGroup,
            onDeleteGroup: { activePrompt = .deleteGroup($0) },
            onExpandAll: { collapsedSectionIDs.removeAll() },
            onCollapseAll: { collapsedSectionIDs = Set(sections.map(\.id)) },
            onSort: { sortOrderRawValue = $0 }
        )
    }

    private func profile(_ id: UUID) -> SessionProfile? {
        model.profiles.first { $0.id == id }
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

    private func applySessionDrop(_ id: SessionProfile.ID, to placement: SessionListPlacement) {
        guard model.moveSession(id, to: placement) else { return }
        sortOrderRawValue = SessionSortOrder.manual.rawValue
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = sections.flatMap { section -> [SessionProfile.ID] in
            collapsedSectionIDs.contains(section.id) ? [] : section.profiles.map(\.id)
        }
        guard !ids.isEmpty else { return }
        guard let current = model.selectedProfileID, let index = ids.firstIndex(of: current) else {
            model.selectedProfileID = ids[0]
            return
        }
        switch direction {
        case .up where index > 0:
            model.selectedProfileID = ids[index - 1]
        case .down where index + 1 < ids.count:
            model.selectedProfileID = ids[index + 1]
        default:
            break
        }
    }
}

struct SessionListSnapshot: Equatable {
    var sections: [SessionSectionSnapshot]
    var selectedID: UUID?
    var allowsDrag: Bool
    var groupNames: [String]
    var sortOrderRaw: String
}

struct SessionSectionSnapshot: Equatable, Identifiable {
    enum Kind: Equatable {
        case favorites
        case ungrouped
        case group(String)

        func placement(over: UUID?) -> SessionListPlacement {
            switch self {
            case .favorites: .favorites(over: over)
            case .ungrouped: .ungrouped(over: over)
            case .group(let name): .group(name, over: over)
            }
        }

        var groupName: String? {
            if case .group(let name) = self { return name }
            return nil
        }
    }

    var id: String
    var title: String
    var systemImage: String
    var kind: Kind
    var isExpanded: Bool
    var rows: [SessionRowSnapshot]
}

struct SessionRowSnapshot: Equatable, Identifiable {
    var id: UUID
    var name: String
    var address: String
    var isFavorite: Bool
    var groupName: String
    var tabStates: [SSHConnectionState]
}

struct SessionListActions {
    var onSelect: (UUID) -> Void
    var onConnect: (UUID) -> Void
    var onToggleExpanded: (String) -> Void
    var onMove: (UUID, SessionListPlacement) -> Void
    var onOpenSFTP: (UUID) -> Void
    var onToggleFavorite: (UUID) -> Void
    var onMoveToGroup: (UUID, String) -> Void
    var onNewGroupForSession: (UUID) -> Void
    var onCopySSH: (UUID) -> Void
    var onRename: (UUID) -> Void
    var onEdit: (UUID) -> Void
    var onDuplicate: (UUID) -> Void
    var onDelete: (UUID) -> Void
    var onCreateSession: (String) -> Void
    var onCreateGroup: () -> Void
    var onRenameGroup: (String) -> Void
    var onDeleteGroup: (String) -> Void
    var onExpandAll: () -> Void
    var onCollapseAll: () -> Void
    var onSort: (String) -> Void
}

struct NativeSessionList: NSViewRepresentable {
    var snapshot: SessionListSnapshot
    var actions: SessionListActions

    func makeNSView(context: Context) -> SessionListHostView {
        let view = SessionListHostView()
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: SessionListHostView, context: Context) {
        nsView.actions = actions
        nsView.reload(snapshot)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SessionListHostView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 260, height: proposal.height ?? 400)
    }
}

private enum SessionListMetrics {
    static let insetX: CGFloat = 8
    static let insetY: CGFloat = 6
    static let headerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 38
    static let rowSpacing: CGFloat = 2
    static let sectionSpacing: CGFloat = 8
    static let corner: CGFloat = 6
    static let dragThreshold: CGFloat = 10
}

final class SessionListHostView: NSView {
    var actions = SessionListActions(
        onSelect: { _ in },
        onConnect: { _ in },
        onToggleExpanded: { _ in },
        onMove: { _, _ in },
        onOpenSFTP: { _ in },
        onToggleFavorite: { _ in },
        onMoveToGroup: { _, _ in },
        onNewGroupForSession: { _ in },
        onCopySSH: { _ in },
        onRename: { _ in },
        onEdit: { _ in },
        onDuplicate: { _ in },
        onDelete: { _ in },
        onCreateSession: { _ in },
        onCreateGroup: {},
        onRenameGroup: { _ in },
        onDeleteGroup: { _ in },
        onExpandAll: {},
        onCollapseAll: {},
        onSort: { _ in }
    )

    private let scrollView = SessionListScrollView()
    private let documentView = SessionFlippedView()
    private let slotPlaceholder: SessionPassthroughView = {
        let view = SessionPassthroughView()
        view.wantsLayer = true
        view.layer?.cornerRadius = SessionListMetrics.corner
        view.layer?.borderWidth = 1.5
        view.isHidden = true
        return view
    }()
    private let insertionCaret: SessionPassthroughView = {
        let view = SessionPassthroughView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 2
        view.isHidden = true
        return view
    }()

    private var snapshot = SessionListSnapshot(
        sections: [],
        selectedID: nil,
        allowsDrag: true,
        groupNames: [],
        sortOrderRaw: "name"
    )
    private var headers: [String: SessionHeaderNSView] = [:]
    private var rows: [UUID: SessionRowNSView] = [:]
    private var mouseMonitor: Any?
    private var trackingID: UUID?
    private var dragStart: NSPoint?
    private var draggingID: UUID?
    private var placement: SessionListPlacement?
    private var laidPlacement: SessionListPlacement?
    private var grabOffsetY: CGFloat = 0
    private var dragPointerY: CGFloat = 0
    private var isShowingContextMenu = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = documentView
        documentView.addSubview(slotPlaceholder)
        documentView.addSubview(insertionCaret)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        guard window != nil else { return }
        // ponytail: local monitor runs before NSHostingView dispatch, which can drop clicks
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            self?.routeMouse(event) ?? event
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutRows()
    }

    func reload(_ snapshot: SessionListSnapshot) {
        self.snapshot = snapshot
        let headerIDs = Set(snapshot.sections.map(\.id))
        let rowIDs = Set(snapshot.sections.flatMap { $0.rows.map(\.id) })
        for (id, view) in headers where !headerIDs.contains(id) {
            view.removeFromSuperview()
            headers.removeValue(forKey: id)
        }
        for (id, view) in rows where !rowIDs.contains(id) && id != draggingID {
            view.removeFromSuperview()
            rows.removeValue(forKey: id)
        }
        for section in snapshot.sections {
            let header = headers[section.id] ?? {
                let created = SessionHeaderNSView()
                created.host = self
                documentView.addSubview(created, positioned: .below, relativeTo: insertionCaret)
                headers[section.id] = created
                return created
            }()
            header.section = section
            header.needsDisplay = true
            for row in section.rows {
                let view = rows[row.id] ?? {
                    let created = SessionRowNSView()
                    created.host = self
                    created.wantsLayer = true
                    created.layer?.masksToBounds = false
                    documentView.addSubview(created, positioned: .below, relativeTo: insertionCaret)
                    rows[row.id] = created
                    return created
                }()
                view.snapshot = row
                view.selected = row.id == snapshot.selectedID
                view.dragging = row.id == draggingID
                view.needsDisplay = true
            }
        }
        layoutRows()
    }

    private func routeMouse(_ event: NSEvent) -> NSEvent? {
        if isShowingContextMenu { return event }
        guard event.window == window else { return event }
        switch event.type {
        case .rightMouseDown:
            return handleSecondaryDown(event) ? nil : event
        case .leftMouseDown:
            if event.modifierFlags.contains(.control) {
                return handleSecondaryDown(event) ? nil : event
            }
            return handlePrimaryDown(event) ? nil : event
        case .leftMouseDragged, .leftMouseUp:
            guard trackingID != nil else { return event }
            handlePrimaryDragOrUp(event)
            return nil
        default:
            return event
        }
    }

    private func handleSecondaryDown(_ event: NSEvent) -> Bool {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return false }
        let documentPoint = documentView.convert(event.locationInWindow, from: nil)
        isShowingContextMenu = true
        if let row = row(at: documentPoint) {
            DispatchQueue.main.async { [weak self, weak row] in
                row?.popContextMenu(event)
                self?.isShowingContextMenu = false
            }
        } else if let header = header(at: documentPoint) {
            DispatchQueue.main.async { [weak self, weak header] in
                header?.popContextMenu(event)
                self?.isShowingContextMenu = false
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSMenu.popUpContextMenu(self.emptyMenu(), with: event, for: self)
                self.isShowingContextMenu = false
            }
        }
        return true
    }

    private func handlePrimaryDown(_ event: NSEvent) -> Bool {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return false }
        let documentPoint = documentView.convert(event.locationInWindow, from: nil)
        if let header = header(at: documentPoint) {
            actions.onToggleExpanded(header.section.id)
            return true
        }
        guard let row = row(at: documentPoint) else { return true }
        actions.onSelect(row.snapshot.id)
        if event.clickCount == 2 {
            actions.onConnect(row.snapshot.id)
            return true
        }
        trackingID = row.snapshot.id
        dragStart = event.locationInWindow
        return true
    }

    private func handlePrimaryDragOrUp(_ event: NSEvent) {
        guard let trackingID, let dragStart else { return }
        if event.type == .leftMouseUp {
            if draggingID != nil { finishDrag() }
            self.trackingID = nil
            self.dragStart = nil
            return
        }
        guard snapshot.allowsDrag else { return }
        let distance = hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y)
        let documentY = documentView.convert(event.locationInWindow, from: nil).y
        if draggingID == nil {
            guard distance >= SessionListMetrics.dragThreshold else { return }
            beginDrag(of: trackingID, documentY: documentY)
        } else {
            updateDrag(of: trackingID, documentY: documentY)
        }
    }

    private func beginDrag(of id: UUID, documentY: CGFloat) {
        draggingID = id
        dragPointerY = documentY
        if let row = rows[id], let rest = restingFrames().rows[id] {
            grabOffsetY = documentY - rest.minY
            documentView.addSubview(row, positioned: .above, relativeTo: insertionCaret)
        }
        laidPlacement = nil
        updatePlacement(documentY: documentY)
        reload(snapshot)
    }

    private func updateDrag(of id: UUID, documentY: CGFloat) {
        draggingID = id
        dragPointerY = documentY
        updatePlacement(documentY: documentY)
        layoutRows()
    }

    private func finishDrag() {
        let sourceID = draggingID
        let dest = placement
        draggingID = nil
        placement = nil
        laidPlacement = nil
        grabOffsetY = 0
        insertionCaret.isHidden = true
        slotPlaceholder.isHidden = true
        reload(snapshot)
        guard let sourceID, let dest else { return }
        actions.onMove(sourceID, dest)
    }

    private func updatePlacement(documentY: CGFloat) {
        guard let sourceID = draggingID else {
            placement = nil
            return
        }
        placement = hitPlacement(y: documentY, source: sourceID)
    }

    private func hitPlacement(y: CGFloat, source: UUID) -> SessionListPlacement? {
        let rest = restingFrames()
        guard let section = section(at: y, rest: rest) else { return placement }
        let ids = section.rows.map(\.id)
        if ids.contains(source) {
            return section.kind.placement(over: verticalTarget(ids: ids, source: source, pointerY: y, frames: rest.rows))
        }
        if let row = section.rows.first(where: { rest.rows[$0.id].map { $0.minY...$0.maxY ~= y } ?? false }) {
            return section.kind.placement(over: row.id)
        }
        return section.kind.placement(over: nil)
    }

    private func section(at y: CGFloat, rest: RestingLayout) -> SessionSectionSnapshot? {
        snapshot.sections.first { section in
            guard let header = rest.headers[section.id] else { return false }
            let bottom = section.rows.compactMap { rest.rows[$0.id]?.maxY }.max() ?? header.maxY
            return (header.minY...bottom).contains(y)
        }
    }

    private func verticalTarget(
        ids: [UUID],
        source: UUID,
        pointerY: CGFloat,
        frames: [UUID: CGRect]
    ) -> UUID? {
        guard let sourceIndex = ids.firstIndex(of: source) else { return nil }
        let mapped = Dictionary(uniqueKeysWithValues: ids.compactMap { id -> (UUID, CGRect)? in
            frames[id].map { (id, CGRect(x: $0.minY, y: 0, width: max($0.height, 1), height: 1)) }
        })
        guard let sourceFrame = mapped[source] else { return nil }
        return TabReorder.targetID(
            sourceIndex: sourceIndex,
            sourceFrame: sourceFrame,
            pointerX: pointerY,
            orderedIDs: ids,
            frames: mapped
        )
    }

    private func row(at documentPoint: NSPoint) -> SessionRowNSView? {
        for section in snapshot.sections.reversed() {
            for row in section.rows.reversed() {
                if let view = rows[row.id], !view.isHidden, view.frame.contains(documentPoint) {
                    return view
                }
            }
        }
        return nil
    }

    private func header(at documentPoint: NSPoint) -> SessionHeaderNSView? {
        for section in snapshot.sections.reversed() {
            if let view = headers[section.id], view.frame.contains(documentPoint) {
                return view
            }
        }
        return nil
    }

    private struct RestingLayout {
        var headers: [String: CGRect]
        var rows: [UUID: CGRect]
    }

    private func restingFrames() -> RestingLayout {
        var headers: [String: CGRect] = [:]
        var rows: [UUID: CGRect] = [:]
        var y = SessionListMetrics.insetY
        let width = max(bounds.width - SessionListMetrics.insetX * 2, 40)
        let x = SessionListMetrics.insetX
        for section in snapshot.sections {
            headers[section.id] = CGRect(x: x, y: y, width: width, height: SessionListMetrics.headerHeight)
            y += SessionListMetrics.headerHeight + SessionListMetrics.rowSpacing
            if section.isExpanded {
                for row in section.rows {
                    rows[row.id] = CGRect(x: x, y: y, width: width, height: SessionListMetrics.rowHeight)
                    y += SessionListMetrics.rowHeight + SessionListMetrics.rowSpacing
                }
            }
            y += SessionListMetrics.sectionSpacing - SessionListMetrics.rowSpacing
        }
        return RestingLayout(headers: headers, rows: rows)
    }

    private func previewIDs(in section: SessionSectionSnapshot) -> [UUID] {
        var ids = section.isExpanded ? section.rows.map(\.id) : []
        guard let draggingID, let placement else {
            return ids.filter { $0 != draggingID }
        }
        if sameSection(placement, section.kind.placement(over: nil)) {
            if !section.isExpanded { return [] }
            if !ids.contains(draggingID) { ids.append(draggingID) }
            return TabReorder.previewIDs(ids, moving: draggingID, over: overID(placement))
        }
        return ids.filter { $0 != draggingID }
    }

    private func sameSection(_ lhs: SessionListPlacement, _ rhs: SessionListPlacement) -> Bool {
        switch (lhs, rhs) {
        case (.favorites, .favorites), (.ungrouped, .ungrouped): true
        case (.group(let a, _), .group(let b, _)): a.localizedCaseInsensitiveCompare(b) == .orderedSame
        default: false
        }
    }

    private func overID(_ placement: SessionListPlacement) -> UUID? {
        switch placement {
        case .favorites(let over), .ungrouped(let over), .group(_, let over): over
        }
    }

    private func layoutRows() {
        let width = max(bounds.width - SessionListMetrics.insetX * 2, 40)
        let x = SessionListMetrics.insetX
        var y = SessionListMetrics.insetY
        var slot: CGRect?
        var neighborRows: [(SessionRowNSView, CGRect)] = []
        var headerFrames: [(SessionHeaderNSView, CGRect, Bool)] = []
        let animateNeighbors = draggingID != nil && placement != laidPlacement
        laidPlacement = placement

        for section in snapshot.sections {
            let headerFrame = CGRect(x: x, y: y, width: width, height: SessionListMetrics.headerHeight)
            let targeted = headerTargeted(section)
            if let header = headers[section.id] {
                header.targeted = targeted
                headerFrames.append((header, headerFrame, false))
            }
            y += SessionListMetrics.headerHeight + SessionListMetrics.rowSpacing

            let ids = previewIDs(in: section)
            if section.isExpanded {
                for id in ids {
                    let frame = CGRect(x: x, y: y, width: width, height: SessionListMetrics.rowHeight)
                    if id == draggingID {
                        slot = frame
                        if let row = rows[id] {
                            row.isHidden = false
                            row.dragging = true
                            row.layer?.zPosition = 10
                            row.frame = CGRect(
                                x: x,
                                y: dragPointerY - grabOffsetY,
                                width: width,
                                height: SessionListMetrics.rowHeight
                            )
                        }
                    } else if let row = rows[id] {
                        row.isHidden = false
                        row.dragging = false
                        row.layer?.zPosition = 0
                        neighborRows.append((row, frame))
                    }
                    y += SessionListMetrics.rowHeight + SessionListMetrics.rowSpacing
                }
            }
            let visible = Set(ids)
            for row in section.rows where row.id != draggingID && !visible.contains(row.id) {
                rows[row.id]?.isHidden = true
            }
            y += SessionListMetrics.sectionSpacing - SessionListMetrics.rowSpacing
        }

        if let draggingID, let row = rows[draggingID], slot == nil {
            row.isHidden = false
            row.dragging = true
            row.layer?.zPosition = 10
            row.frame = CGRect(
                x: x,
                y: dragPointerY - grabOffsetY,
                width: width,
                height: SessionListMetrics.rowHeight
            )
        }

        let apply = { (animated: Bool) in
            for (header, frame, _) in headerFrames {
                if animated {
                    header.animator().frame = frame
                } else {
                    header.frame = frame
                }
                header.needsDisplay = true
            }
            for (row, frame) in neighborRows {
                if animated {
                    row.animator().frame = frame
                } else {
                    row.frame = frame
                }
            }
            self.updateDragMarkers(slot: slot, animated: animated)
        }
        if animateNeighbors {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                apply(true)
            }
        } else {
            apply(false)
        }

        let height = max(y + SessionListMetrics.insetY, bounds.height)
        documentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
    }

    private func headerTargeted(_ section: SessionSectionSnapshot) -> Bool {
        guard let draggingID, let placement,
              !section.rows.contains(where: { $0.id == draggingID }) else { return false }
        switch (section.kind, placement) {
        case (.favorites, .favorites(let over)), (.ungrouped, .ungrouped(let over)):
            return over == nil
        case (.group(let name), .group(let other, let over)):
            return over == nil && name.localizedCaseInsensitiveCompare(other) == .orderedSame
        default:
            return false
        }
    }

    private func updateDragMarkers(slot: CGRect?, animated: Bool) {
        slotPlaceholder.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        slotPlaceholder.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        insertionCaret.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionCaret.layer?.zPosition = 9
        guard let slot, draggingID != nil else {
            slotPlaceholder.isHidden = true
            insertionCaret.isHidden = true
            return
        }

        slotPlaceholder.isHidden = false
        if animated {
            slotPlaceholder.animator().frame = slot
        } else {
            slotPlaceholder.frame = slot
        }

        let caret = CGRect(x: slot.midX - 10, y: slot.minY - 2, width: 20, height: 4)
        let hasOver: Bool = {
            switch placement {
            case .favorites(let over), .ungrouped(let over), .group(_, let over):
                over != nil
            case .none:
                false
            }
        }()
        if hasOver, insertionCaret.isHidden {
            insertionCaret.frame = caret
            insertionCaret.isHidden = false
        } else if hasOver {
            insertionCaret.isHidden = false
            if animated {
                insertionCaret.animator().frame = caret
            } else {
                insertionCaret.frame = caret
            }
        } else {
            insertionCaret.isHidden = true
        }
    }

    fileprivate func emptyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(hostItem(String(localized: "New Session…"), #selector(createSession)))
        menu.addItem(hostItem(String(localized: "New Group…"), #selector(createGroup)))
        menu.addItem(.separator())
        let sort = NSMenuItem(title: String(localized: "Sort By"), action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        for (title, raw) in [
            (String(localized: "Manual"), "manual"),
            (String(localized: "Name"), "name"),
            (String(localized: "Host"), "host"),
            (String(localized: "Last Used"), "recent"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(chooseSort(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = raw
            item.state = snapshot.sortOrderRaw == raw ? .on : .off
            sortMenu.addItem(item)
        }
        sort.submenu = sortMenu
        menu.addItem(sort)
        menu.addItem(.separator())
        menu.addItem(hostItem(String(localized: "Expand All"), #selector(expandAll)))
        menu.addItem(hostItem(String(localized: "Collapse All"), #selector(collapseAll)))
        return menu
    }

    private func hostItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func createSession() { actions.onCreateSession("") }
    @objc private func createGroup() { actions.onCreateGroup() }
    @objc private func expandAll() { actions.onExpandAll() }
    @objc private func collapseAll() { actions.onCollapseAll() }
    @objc private func chooseSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        actions.onSort(raw)
    }
}

private final class SessionHeaderNSView: NSView {
    weak var host: SessionListHostView?
    var section = SessionSectionSnapshot(
        id: "",
        title: "",
        systemImage: "folder",
        kind: .ungrouped,
        isExpanded: true,
        rows: []
    )
    var targeted = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if targeted {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        }

        let chevronName = section.isExpanded ? "chevron.down" : "chevron.right"
        drawSymbol(chevronName, in: NSRect(x: 4, y: (bounds.height - 10) / 2, width: 10, height: 10), color: .secondaryLabelColor)
        drawSymbol(section.systemImage, in: NSRect(x: 18, y: (bounds.height - 13) / 2, width: 13, height: 13), color: .labelColor)

        let titleFont = NSFont.systemFont(ofSize: 13)
        let count = "\(section.rows.count)" as NSString
        let countSize = count.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
        let titleRect = NSRect(
            x: 36,
            y: (bounds.height - titleFont.boundingRectForFont.height) / 2,
            width: max(bounds.width - 48 - countSize.width, 0),
            height: titleFont.boundingRectForFont.height
        )
        (section.title as NSString).draw(in: titleRect, withAttributes: [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor,
        ])
        count.draw(
            in: NSRect(x: bounds.width - countSize.width - 6, y: (bounds.height - countSize.height) / 2, width: countSize.width, height: countSize.height),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
    }

    func popContextMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if let groupName = section.kind.groupName {
            menu.addItem(item(String(localized: "New Session in Group…"), #selector(createInGroup)))
            menu.items.last?.representedObject = groupName
        } else {
            menu.addItem(item(String(localized: "New Session…"), #selector(createSession)))
        }
        menu.addItem(item(String(localized: "New Group…"), #selector(createGroup)))
        menu.addItem(.separator())
        if section.isExpanded {
            menu.addItem(item(String(localized: "Collapse Group"), #selector(toggle)))
        } else {
            menu.addItem(item(String(localized: "Expand Group"), #selector(toggle)))
        }
        if section.kind.groupName != nil {
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Rename Group…"), #selector(renameGroup)))
            menu.addItem(item(String(localized: "Delete Group"), #selector(deleteGroup)))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func createSession() { host?.actions.onCreateSession("") }
    @objc private func createInGroup() {
        host?.actions.onCreateSession(section.kind.groupName ?? "")
    }
    @objc private func createGroup() { host?.actions.onCreateGroup() }
    @objc private func toggle() { host?.actions.onToggleExpanded(section.id) }
    @objc private func renameGroup() {
        if let name = section.kind.groupName { host?.actions.onRenameGroup(name) }
    }
    @objc private func deleteGroup() {
        if let name = section.kind.groupName { host?.actions.onDeleteGroup(name) }
    }
}

private final class SessionRowNSView: NSView {
    weak var host: SessionListHostView?
    var snapshot = SessionRowSnapshot(
        id: UUID(),
        name: "",
        address: "",
        isFavorite: false,
        groupName: "",
        tabStates: []
    )
    var selected = false
    var dragging = false {
        didSet { applyDragChrome() }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(snapshot.name)
        setAccessibilitySelected(selected)
        toolTip = helpText

        let path = NSBezierPath(roundedRect: bounds, xRadius: SessionListMetrics.corner, yRadius: SessionListMetrics.corner)
        if dragging {
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        } else if selected {
            NSColor.systemBlue.setFill()
            path.fill()
        }

        let iconColor: NSColor = selected && !dragging ? .white : .labelColor
        drawSymbol("server.rack", in: NSRect(x: 8, y: (bounds.height - 14) / 2, width: 14, height: 14), color: iconColor)
        if let status = statusColor {
            let dot = NSRect(x: 18, y: (bounds.height - 14) / 2 - 1, width: 7, height: 7)
            status.setFill()
            NSBezierPath(ovalIn: dot).fill()
            (selected && !dragging ? NSColor.systemBlue : NSColor.controlBackgroundColor).setStroke()
            let stroke = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            stroke.lineWidth = 1
            stroke.stroke()
        }

        let titleFont = NSFont.systemFont(ofSize: 13)
        let subtitleFont = NSFont.systemFont(ofSize: 11)
        let titleColor: NSColor = selected && !dragging ? .white : .labelColor
        let subtitleColor: NSColor = selected && !dragging ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        var trailing: CGFloat = 8
        if snapshot.tabStates.count > 1 {
            let text = "\(snapshot.tabStates.count)" as NSString
            let size = text.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)])
            let badge = NSRect(x: bounds.width - trailing - size.width - 10, y: (bounds.height - size.height - 2) / 2, width: size.width + 10, height: size.height + 2)
            (selected && !dragging ? NSColor.white.withAlphaComponent(0.22) : NSColor.secondaryLabelColor.withAlphaComponent(0.14)).setFill()
            NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
            text.draw(
                in: NSRect(x: badge.minX, y: badge.minY + 1, width: badge.width, height: size.height),
                withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: titleColor,
                    .paragraphStyle: centered,
                ]
            )
            trailing += badge.width + 6
        }
        if snapshot.isFavorite {
            drawSymbol(
                "star.fill",
                in: NSRect(x: bounds.width - trailing - 12, y: (bounds.height - 11) / 2, width: 11, height: 11),
                color: selected && !dragging ? .white : .systemOrange
            )
            trailing += 16
        }

        let textWidth = max(bounds.width - 30 - trailing, 0)
        let titleHeight = titleFont.boundingRectForFont.height
        let subtitleHeight = subtitleFont.boundingRectForFont.height
        let block = titleHeight + 2 + subtitleHeight
        let top = (bounds.height - block) / 2
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (snapshot.name as NSString).draw(
            in: NSRect(x: 28, y: top, width: textWidth, height: titleHeight),
            withAttributes: [.font: titleFont, .foregroundColor: titleColor, .paragraphStyle: style]
        )
        (snapshot.address as NSString).draw(
            in: NSRect(x: 28, y: top + titleHeight + 2, width: textWidth, height: subtitleHeight),
            withAttributes: [.font: subtitleFont, .foregroundColor: subtitleColor, .paragraphStyle: style]
        )
    }

    private var centered: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }

    private var statusColor: NSColor? {
        if snapshot.tabStates.isEmpty { return nil }
        if snapshot.tabStates.contains(.connected) { return .systemGreen }
        if snapshot.tabStates.contains(.connecting) { return .systemYellow }
        if snapshot.tabStates.contains(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            return .systemRed
        }
        return .secondaryLabelColor
    }

    private var helpText: String {
        guard !snapshot.tabStates.isEmpty else { return snapshot.address }
        let tabCount = snapshot.tabStates.count == 1
            ? String(localized: "1 open tab")
            : String(format: String(localized: "%lld open tabs"), Int64(snapshot.tabStates.count))
        let status: String
        if snapshot.tabStates.contains(.connected) {
            status = String(localized: "Connected")
        } else if snapshot.tabStates.contains(.connecting) {
            status = String(localized: "Connecting")
        } else if snapshot.tabStates.contains(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            status = String(localized: "Connection Failed")
        } else {
            status = String(localized: "Disconnected")
        }
        return "\(snapshot.address) — \(tabCount) — \(status)"
    }

    private func applyDragChrome() {
        wantsLayer = true
        layer?.masksToBounds = false
        if dragging {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.25
            layer?.shadowRadius = 8
            layer?.shadowOffset = CGSize(width: 0, height: 3)
        } else {
            layer?.shadowOpacity = 0
        }
        needsDisplay = true
    }

    func popContextMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        host?.actions.onSelect(snapshot.id)
        return true
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Connect"), #selector(connect)))
        menu.addItem(item(String(localized: "Open SFTP"), #selector(openSFTP)))
        menu.addItem(.separator())
        menu.addItem(item(
            snapshot.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
            #selector(toggleFavorite)
        ))
        let group = NSMenuItem(title: String(localized: "Move to Group"), action: nil, keyEquivalent: "")
        let groupMenu = NSMenu()
        let sessions = NSMenuItem(title: String(localized: "Sessions"), action: #selector(moveToSessions), keyEquivalent: "")
        sessions.target = self
        sessions.isEnabled = !snapshot.groupName.isEmpty
        groupMenu.addItem(sessions)
        for name in host?.snapshotGroups ?? [] {
            let item = NSMenuItem(title: name, action: #selector(moveToNamedGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.isEnabled = snapshot.groupName != name
            groupMenu.addItem(item)
        }
        groupMenu.addItem(.separator())
        groupMenu.addItem(item(String(localized: "New Group…"), #selector(newGroup)))
        group.submenu = groupMenu
        menu.addItem(group)
        menu.addItem(item(String(localized: "Copy SSH Command"), #selector(copySSH)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Rename…"), #selector(rename)))
        menu.addItem(item(String(localized: "Edit"), #selector(edit)))
        menu.addItem(item(String(localized: "Duplicate"), #selector(duplicate)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Delete"), #selector(deleteSession)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func connect() { host?.actions.onConnect(snapshot.id) }
    @objc private func openSFTP() { host?.actions.onOpenSFTP(snapshot.id) }
    @objc private func toggleFavorite() { host?.actions.onToggleFavorite(snapshot.id) }
    @objc private func moveToSessions() { host?.actions.onMoveToGroup(snapshot.id, "") }
    @objc private func moveToNamedGroup(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        host?.actions.onMoveToGroup(snapshot.id, name)
    }
    @objc private func newGroup() { host?.actions.onNewGroupForSession(snapshot.id) }
    @objc private func copySSH() { host?.actions.onCopySSH(snapshot.id) }
    @objc private func rename() { host?.actions.onRename(snapshot.id) }
    @objc private func edit() { host?.actions.onEdit(snapshot.id) }
    @objc private func duplicate() { host?.actions.onDuplicate(snapshot.id) }
    @objc private func deleteSession() { host?.actions.onDelete(snapshot.id) }
}

extension SessionListHostView {
    var snapshotGroups: [String] { snapshot.groupNames }
}

private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
    let config = NSImage.SymbolConfiguration(pointSize: max(rect.height, 11), weight: .regular)
        .applying(.init(hierarchicalColor: color))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    image.draw(in: rect)
}

private final class SessionListScrollView: NSScrollView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class SessionPassthroughView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SessionFlippedView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    @Environment(AppModel.self) private var model
    @Binding var state: SessionEditorState
    var onCancel: () -> Void
    var onSave: () -> Void
    @State private var keyPath = ""
    @State private var certificateValidationFailure: String?

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
                } else if state.profile.authMethod == .privateKey {
                    SecureField("Passphrase", text: $state.secret)
                    LabeledContent("Private Key") {
                        Button(keyPath.isEmpty ? keyLabel : keyPath) { chooseKey() }
                    }
                } else {
                    SSHAgentIdentityEditor(configuration: $state.profile.agent)
                }
                if state.profile.authMethod != .password {
                    SSHCertificateEditor(configuration: $state.profile.certificate,
                                         validationFailure: $certificateValidationFailure,
                                         agentPublicKey: state.profile.authMethod == .agent ? state.profile.agent.publicKey : nil)
                }
            }
            Section("Jump Host") {
                Picker("Connect via", selection: $state.profile.jumpHostID) {
                    Text("Direct Connection").tag(UUID?.none)
                    ForEach(model.profiles.filter { $0.id != state.profile.id }) { profile in
                        Text(verbatim: "\(profile.displayName) — \(profile.username)@\(profile.host):\(profile.port)")
                            .tag(Optional(profile.id))
                    }
                    if let id = state.profile.jumpHostID,
                       !model.profiles.contains(where: { $0.id == id && id != state.profile.id }) {
                        Text("Unavailable Jump Host").tag(Optional(id))
                    }
                }
                Text("Each jump uses its own saved credentials and host-key verification. The destination is reached from the last jump host.")
                    .font(.caption).foregroundStyle(.secondary)
                if let routeError {
                    Text(verbatim: routeError).font(.caption).foregroundStyle(.red)
                } else if state.profile.jumpHostID != nil, let route = try? resolvedRoute() {
                    Text(verbatim: route.map(\.displayName).joined(separator: " → "))
                        .font(.caption).textSelection(.enabled)
                }
            }
            Section {
                TextField("Startup Command", text: $state.profile.startupCommand)
                TextField("Group", text: $state.profile.groupName)
                Toggle("Favorite", isOn: $state.profile.isFavorite)
            }
            Section("Port Forwarding") {
                PortForwardRuleEditor(rules: $state.profile.portForwards)
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
        .onChange(of: state.profile.authMethod) {
            if state.profile.authMethod == .password {
                state.profile.certificate.enabled = false
                certificateValidationFailure = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: onSave)
                    .disabled(!state.profile.isValidForSaving || certificateValidationFailure != nil || routeError != nil || PortForwardRule.validationError(in: state.profile.portForwards) != nil)
            }
        }
    }

    private func resolvedRoute() throws -> [SessionProfile] {
        try SSHConnectionRoute.resolve(destination: state.profile, profiles: model.profiles)
    }

    private var routeError: String? {
        // Other fields display their own validation messages while a new session is being entered.
        guard state.profile.isValidForSaving else { return nil }
        do { _ = try resolvedRoute(); return nil }
        catch { return error.localizedDescription }
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

struct PortForwardRuleEditor: View {
    @Binding var rules: [PortForwardRule]

    var body: some View {
        Text("Enabled rules start with this terminal connection. SFTP windows and jump hosts do not start these rules.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach($rules) { $rule in
            VStack(alignment: .leading, spacing: 10) {
                Picker("Type", selection: $rule.kind) {
                    ForEach(PortForwardKind.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                TextField("Listen address", text: $rule.bindHost)
                TextField("Listen port", value: $rule.bindPort, format: .number.grouping(.never))
                if rule.kind != .dynamic {
                    TextField("Destination host", text: $rule.destinationHost)
                    TextField("Destination port", value: $rule.destinationPort, format: .number.grouping(.never))
                }
                Text(rule.kind == .remote
                     ? "Listen on the SSH server; connect to the destination from this Mac."
                     : rule.kind == .local
                     ? "Listen on this Mac; connect to the destination from the SSH server."
                     : "SOCKS5 CONNECT proxy on this Mac. Domain names are resolved by the SSH server. TCP only; no authentication.")
                    .font(.caption).foregroundStyle(.secondary)
                if rule.exposesNetwork {
                    Text("Warning: this address may expose the forwarded service or unauthenticated proxy to other computers. Prefer 127.0.0.1 or ::1 for private use. Remote exposure also depends on the server's GatewayPorts policy.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Toggle("Start on connect", isOn: $rule.isEnabled)
                    Spacer()
                    Button("Remove Rule", role: .destructive) { rules.removeAll { $0.id == rule.id } }
                }
            }
            .padding(.vertical, 6)
        }
        Button("Add Forwarding Rule", systemImage: "plus") {
            let used = Set(rules.filter { $0.kind != .remote }.map(\.bindPort))
            let port = (8080...8112).first { !used.contains($0) } ?? 8080
            rules.append(PortForwardRule(bindPort: port))
        }
        .disabled(rules.count >= 32)
        if let error = PortForwardRule.validationError(in: rules) {
            Text(verbatim: error).font(.caption).foregroundStyle(.red)
        }
        Text("Use the tab's Port Forwarding menu to inspect, start, or stop individual rules. Editing saved rules takes effect after reconnecting.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
