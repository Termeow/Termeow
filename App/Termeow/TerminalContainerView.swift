import AppKit
import SwiftUI
import TermeowKit
import UniformTypeIdentifiers

private let sessionTabDragType = UTType(exportedAs: "cn.termeow.session-tab")

struct GroupWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.findBarVisible { FindBar() }
            GroupLayoutView(
                layout: model.tabGroups.maximizedGroupID.map(PaneLayout.leaf) ?? model.tabGroups.layout,
                path: "r"
            )
        }
        .alert("Close Tab Group?", isPresented: Binding(
            get: { model.groupPendingClosure != nil },
            set: { if !$0 { model.groupPendingClosure = nil } }
        )) {
            Button("Cancel", role: .cancel) { model.groupPendingClosure = nil }
            Button("Close and Disconnect", role: .destructive) {
                if let id = model.groupPendingClosure { model.closeGroup(id) }
            }
        } message: {
            let count = model.tabGroups.groups.first { $0.id == model.groupPendingClosure }?.tabIDs.count ?? 0
            Text("Closing this group closes all \(count) tabs and disconnects their sessions.")
        }
    }
}

private struct GroupLayoutView: View {
    @Environment(AppModel.self) private var model
    let layout: PaneLayout
    let path: String

    var body: some View {
        content
    }

    private var content: AnyView {
        switch layout {
        case .leaf(let id): return AnyView(SessionTabGroupView(groupID: id))
        case .split(let axis, let first, let second):
            return AnyView(GeometryReader { geometry in
                let vertical = axis == .vertical
                let length = max(0, (vertical ? geometry.size.width : geometry.size.height) - 6)
                let ratio = model.tabGroups.ratios[path] ?? 0.5
                let firstLength = length * ratio
                let stack = vertical ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                stack {
                    GroupLayoutView(layout: first, path: path + "0")
                        .frame(width: vertical ? firstLength : geometry.size.width, height: vertical ? geometry.size.height : firstLength)
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: vertical ? 6 : geometry.size.width, height: vertical ? geometry.size.height : 6)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                            else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(coordinateSpace: .named(path)).onChanged { value in
                            guard length > 0 else { return }
                            model.setGroupRatio((vertical ? value.location.x : value.location.y) / length, path: path, save: false)
                        }.onEnded { _ in model.persist() })
                        .onTapGesture(count: 2) { model.setGroupRatio(0.5, path: path, save: true) }
                        .accessibilityLabel("Resize Tab Groups")
                    GroupLayoutView(layout: second, path: path + "1")
                        .frame(width: vertical ? length - firstLength : geometry.size.width, height: vertical ? geometry.size.height : length - firstLength)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .coordinateSpace(name: path)
                .clipped()
            })
        }
    }
}

private struct SessionTabGroupView: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID
    @State private var dropDirection: SplitDirection?
    @State private var dropVisible = false

    private var group: TerminalTabGroup? { model.tabGroups.groups.first { $0.id == groupID } }
    private var isActive: Bool { model.tabGroups.activeGroupID == groupID }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(group?.tabIDs ?? [], id: \.self) { id in
                            if let tab = model.tabs.first(where: { $0.id == id }) {
                                tabChip(tab)
                            }
                        }
                    }.padding(4)
                }.scrollIndicators(.hidden)
                Menu {
                    groupActions
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                    .help("Tab Group Actions")
            }
            .frame(height: 34)
            .background(isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .contextMenu { groupActions }
            .onDrop(of: [sessionTabDragType], isTargeted: nil) { providers in accept(providers) }
            GeometryReader { geometry in
                ZStack {
                    if let id = group?.selectedTabID, let tab = model.tabs.first(where: { $0.id == id }) {
                        TerminalViewRepresentable(
                            controller: tab.controller, typography: model.typography,
                            colorSchemeID: model.colorSchemeID, isActive: isActive
                        ).id(ObjectIdentifier(tab.controller))
                    } else {
                        VStack(spacing: 12) {
                            Text("Empty Tab Group").font(.headline)
                            Text("Drag a tab here or connect a saved session.").foregroundStyle(.secondary)
                            Button("Connect Selected Session") {
                                model.activateGroup(groupID, focus: false)
                                model.connectSelected()
                            }.disabled(model.selectedProfile == nil)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { model.activateGroup(groupID) }
                    }
                    if dropVisible {
                        dropPreview(in: geometry.size)
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [sessionTabDragType], delegate: GroupDropDelegate(
                    size: geometry.size,
                    changed: { direction, visible in dropDirection = direction; dropVisible = visible },
                    accept: { providers, direction in accept(providers, direction: direction) }
                ))
            }
        }
        .overlay(Rectangle().stroke(isActive && model.tabGroups.groups.count > 1 ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
        .clipped()
    }

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tab.state == .connected ? Color.green : (tab.state == .connecting ? .yellow : .secondary)).frame(width: 6, height: 6)
            Text(tab.controller.title).lineLimit(1).frame(maxWidth: 180)
            Button { model.requestCloseTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.borderless).help("Close Tab")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(group?.selectedTabID == tab.id ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectTab(tab.id); model.focusActiveTerminal() }
        .background(TabDragSource(id: tab.id, title: tab.controller.title) {
            model.selectTab(tab.id); model.focusActiveTerminal()
        })
        .onDrop(of: [sessionTabDragType], isTargeted: nil) { providers in accept(providers, before: tab.id) }
        .contextMenu {
            Button("Connect") { model.reconnectTab(tab.id) }.disabled(!tab.controller.canReconnect)
            Button("Disconnect") { model.disconnectTab(tab.id) }.disabled(!tab.controller.canDisconnect)
            Button("Duplicate Connection") { model.selectTab(tab.id); model.duplicateTab(tab.id) }
            Button("Open SFTP") { model.openSFTP(tab.controller.profile) }
            Divider()
            Menu("Move to New Tab Group") {
                ForEach(SplitDirection.allCases, id: \.self) { direction in
                    Button(directionTitle(direction)) { model.moveSessionTab(tab.id, to: groupID, direction: direction) }
                        .disabled(group?.tabIDs.count == 1)
                }
            }
            Menu("Move to Tab Group") {
                ForEach(Array(model.tabGroups.layout.paneIDs.enumerated()), id: \.element) { index, id in
                    Button("Group \(index + 1)") { model.moveSessionTab(tab.id, to: id) }.disabled(id == groupID)
                }
            }.disabled(model.tabGroups.groups.count < 2)
            Divider()
            Button("Close Tab") { model.requestCloseTab(tab.id) }
            Button("Close Other Tabs") { model.closeOtherTabs(keeping: tab.id) }
            Button("Close Tabs to the Right") { model.closeTabsToRight(of: tab.id) }
                .disabled(!model.hasTabsToRight(of: tab.id))
        }
    }

    @ViewBuilder private var groupActions: some View {
        Menu("New Tab Group") {
            ForEach(SplitDirection.allCases, id: \.self) { direction in
                Button(directionTitle(direction)) { model.activateGroup(groupID, focus: false); model.createGroup(direction) }
            }
        }.disabled(model.tabGroups.groups.count >= 16)
        Button("New Saved Session…") { model.activateGroup(groupID, focus: false); model.beginNewSession() }
        Divider()
        Button(model.tabGroups.maximizedGroupID == nil ? "Maximize Tab Group" : "Restore Tab Groups") {
            model.activateGroup(groupID, focus: false); model.toggleGroupZoom()
        }.disabled(model.tabGroups.groups.count < 2)
        Button("Equalize Tab Groups") { model.equalizeGroups() }
        Button("Merge All Tab Groups") { model.mergeAllGroups() }.disabled(model.tabGroups.groups.count < 2)
        Divider()
        Button("Close Tab Group") { model.requestCloseGroup(groupID) }
    }

    private func directionTitle(_ direction: SplitDirection) -> LocalizedStringKey {
        switch direction { case .left: "Left"; case .right: "Right"; case .up: "Above"; case .down: "Below" }
    }

    private func accept(_ providers: [NSItemProvider], direction: SplitDirection? = nil, before: UUID? = nil) -> Bool {
        guard let provider = providers.first, provider.hasItemConformingToTypeIdentifier(sessionTabDragType.identifier) else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: sessionTabDragType.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), text.hasPrefix("termeow-tab:"),
                  let id = UUID(uuidString: String(text.dropFirst(12))) else { return }
            Task { @MainActor in model.moveSessionTab(id, to: groupID, direction: direction, before: before) }
        }
        return true
    }

    private func dropPreview(in size: CGSize) -> some View {
        let horizontal = dropDirection == .left || dropDirection == .right
        return Rectangle().fill(Color.accentColor.opacity(0.25))
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 3))
            .frame(width: dropDirection == nil || !horizontal ? size.width : size.width / 2,
                   height: dropDirection == nil || horizontal ? size.height : size.height / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: dropDirection == .left ? .leading : dropDirection == .right ? .trailing : dropDirection == .up ? .top : dropDirection == .down ? .bottom : .center)
    }
}

private struct TabDragSource: NSViewRepresentable {
    let id: UUID
    let title: String
    let select: () -> Void

    func makeNSView(context: Context) -> TabDragSourceView { TabDragSourceView() }
    func updateNSView(_ view: TabDragSourceView, context: Context) {
        view.tabID = id
        view.title = title
        view.select = select
    }
    static func dismantleNSView(_ view: TabDragSourceView, coordinator: ()) { view.stopMonitoring() }
}

private final class TabDragSourceView: NSView, NSDraggingSource {
    var tabID = UUID()
    var title = ""
    var select: () -> Void = {}
    private var monitor: Any?
    private var start: NSPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        start = nil
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        guard event.window == window else { return event }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown {
            guard !event.modifierFlags.contains(.control), visibleRect.contains(point),
                  point.x < bounds.maxX - 22 else { return event }
            start = point
            return nil
        }
        guard let start else { return event }
        if event.type == .leftMouseUp {
            self.start = nil
            if visibleRect.contains(point) { select() }
            return nil
        }
        guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return nil }
        self.start = nil
        let pasteboard = NSPasteboardItem()
        pasteboard.setData(Data(("termeow-tab:" + tabID.uuidString).utf8), forType: NSPasteboard.PasteboardType(sessionTabDragType.identifier))
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let preview = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            (self.title as NSString).draw(at: NSPoint(x: 8, y: 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
            ])
            return true
        }
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
        return nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

private struct GroupDropDelegate: DropDelegate {
    let size: CGSize
    let changed: (SplitDirection?, Bool) -> Void
    let accept: ([NSItemProvider], SplitDirection?) -> Bool
    func dropUpdated(info: DropInfo) -> DropProposal? {
        changed(direction(info.location), true)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { changed(nil, false) }
    func performDrop(info: DropInfo) -> Bool {
        changed(nil, false)
        return accept(info.itemProviders(for: [sessionTabDragType]), direction(info.location))
    }
    private func direction(_ point: CGPoint) -> SplitDirection? {
        guard size.width > 0, size.height > 0 else { return nil }
        let distances: [(SplitDirection, CGFloat)] = [(.left, point.x / size.width), (.right, 1 - point.x / size.width), (.up, point.y / size.height), (.down, 1 - point.y / size.height)]
        return distances.min(by: { $0.1 < $1.1 }).flatMap { $0.1 < 0.25 ? $0.0 : nil }
    }
}


struct FindBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            TextField("Find", text: $model.findQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.performFind(forward: true) }
            Toggle("Case sensitive", isOn: $model.findCaseSensitive)
                .toggleStyle(.checkbox)
            Group {
                if model.findMatchTotal == 0 {
                    Text("No results")
                } else {
                    Text(verbatim: "\(model.findMatchIndex)/\(model.findMatchTotal)")
                }
            }
            .foregroundStyle(.secondary)
            .frame(minWidth: 70, alignment: .leading)
            Button("Previous") { model.performFind(forward: false) }
            Button("Next") { model.performFind(forward: true) }
            Button("Done") { model.dismissFind() }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .onChange(of: model.findQuery) { _, _ in model.performFind(forward: true) }
        .onChange(of: model.findCaseSensitive) { _, _ in model.performFind(forward: true) }
        .onAppear { model.performFind(forward: true) }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    var controller: ConnectionController
    var typography: TerminalTypography
    var colorSchemeID: TerminalColorSchemeID
    var isActive: Bool = false

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView(terminal: controller.hostedTerminal())
        host.shouldFocus = isActive
        host.onFocus = { controller.noteFocus() }
        applyAppearance(to: host)
        DispatchQueue.main.async {
            if host.shouldFocus, host.terminal.superview === host { host.window?.makeFirstResponder(host.terminal) }
        }
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.shouldFocus = isActive
        host.attach(controller.hostedTerminal())
        host.onFocus = { controller.noteFocus() }
        applyAppearance(to: host)
    }

    private func applyAppearance(to host: TerminalHostView) {
        host.terminal.applyTypography(typography)
        host.terminal.applyColorScheme(colorSchemeID)
        host.applyBackground(colorSchemeID.scheme)
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: ()) {
        host.detach()
    }
}

final class TerminalHostView: NSView {
    private(set) var terminal: SSHTerminalView
    var onFocus: (() -> Void)?
    var shouldFocus = false
    private var mouseMonitor: Any?

    init(terminal: SSHTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        applyBackground(.dark)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        attach(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalHostView is created in code")
    }

    func attach(_ terminal: SSHTerminalView) {
        if self.terminal !== terminal || terminal.superview !== self {
            if self.terminal.superview === self { self.terminal.removeFromSuperview() }
            self.terminal = terminal
            terminal.translatesAutoresizingMaskIntoConstraints = true
            terminal.autoresizingMask = []
            addSubview(terminal)
        }
        applyFrame()
    }

    func applyBackground(_ scheme: TerminalColorScheme) {
        layer?.backgroundColor = scheme.background.cgColor
    }

    func detach() {
        if terminal.superview === self { terminal.removeFromSuperview() }
        onFocus = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    override func layout() {
        super.layout()
        applyFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                self.onFocus?()
            }
            return event
        }
    }

    private func applyFrame() {
        guard terminal.superview === self else { return }
        let size = bounds.size
        guard size.width >= 80, size.height >= 40 else { return }
        if terminal.frame != bounds {
            terminal.frame = bounds
        }
    }
}
