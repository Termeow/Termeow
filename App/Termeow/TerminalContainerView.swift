import AppKit
import SwiftUI
import TermeowKit
import UniformTypeIdentifiers

struct GroupWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.findBarVisible { FindBar() }
            WorkspaceDropHost(model: model)

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


struct GroupLayoutView: View {
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

    private var group: TerminalTabGroup? { model.tabGroups.groups.first { $0.id == groupID } }
    private var isActive: Bool { model.tabGroups.activeGroupID == groupID }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GroupTabStrip(model: model, groupID: groupID)
                    .frame(maxWidth: .infinity)
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
                }

            }
        }
        .overlay(Rectangle().stroke(isActive && model.tabGroups.groups.count > 1 ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
        .clipped()
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
