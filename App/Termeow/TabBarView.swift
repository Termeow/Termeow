import AppKit
import SwiftUI
import TermeowKit
import UniformTypeIdentifiers

let sessionTabDragType = UTType(exportedAs: "cn.termeow.session-tab")
private let tabPasteboardType = NSPasteboard.PasteboardType(sessionTabDragType.identifier)

@MainActor private func draggedSessionID(_ sender: NSDraggingInfo) -> UUID? {
    guard sender.draggingSource is SessionTabDocumentView,
          let data = sender.draggingPasteboard.data(forType: tabPasteboardType),
          let text = String(data: data, encoding: .utf8), text.hasPrefix("termeow-tab:") else { return nil }
    return UUID(uuidString: String(text.dropFirst(12)))
}

struct WorkspaceDropHost: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> WorkspaceDropHostView { WorkspaceDropHostView(model: model) }
    func updateNSView(_ view: WorkspaceDropHostView, context: Context) {}
}

private struct HostedGroupLayout: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        GroupLayoutView(layout: model.tabGroups.maximizedGroupID.map(PaneLayout.leaf) ?? model.tabGroups.layout, path: "r")
    }
}

/// A native ancestor receives terminal-area drops that child tab strips do not handle.
final class WorkspaceDropHostView: NSView {
    private let model: AppModel
    private let content: NSHostingView<AnyView>
    private let preview = DropPreviewView()
    override var isFlipped: Bool { true }

    init(model: AppModel) {
        self.model = model
        content = NSHostingView(rootView: AnyView(HostedGroupLayout().environment(model)))
        content.sizingOptions = []
        super.init(frame: .zero)
        addSubview(content)
        addSubview(preview)
        preview.isHidden = true
        registerForDraggedTypes([tabPasteboardType])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Created in code") }
    override func layout() { super.layout(); content.frame = bounds }

    func outerEdge(at windowPoint: CGPoint) -> SplitDirection? {
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point) else { return nil }
        let distances: [(SplitDirection, CGFloat)] = [(.left, point.x), (.right, bounds.width - point.x), (.up, point.y), (.down, bounds.height - point.y)]
        return distances.min { $0.1 < $1.1 }.flatMap { $0.1 <= 16 ? $0.0 : nil }
    }

    private func target(_ sender: NSDraggingInfo) -> (group: UUID?, direction: SplitDirection?, rect: CGRect)? {
        guard let source = draggedSessionID(sender), model.tabs.contains(where: { $0.id == source }) else { return nil }
        if let edge = outerEdge(at: sender.draggingLocation) {
            guard model.tabs.count > 1, model.tabGroups.groups.count < 16 else { return nil }
            return (nil, edge, half(bounds, direction: edge))
        }
        let point = convert(sender.draggingLocation, from: nil)
        let frames = model.tabGroups.maximizedGroupID.map { [$0: bounds] } ?? model.tabGroups.frames(in: bounds, dividerThickness: 6)
        guard let (id, frame) = frames.first(where: { $0.value.contains(point) }) else { return nil }
        let distances: [(SplitDirection, CGFloat)] = [(.left, (point.x - frame.minX) / frame.width), (.right, (frame.maxX - point.x) / frame.width), (.up, (point.y - frame.minY) / frame.height), (.down, (frame.maxY - point.y) / frame.height)]
        let direction = distances.min { $0.1 < $1.1 }.flatMap { $0.1 < 0.2 ? $0.0 : nil }
        if direction != nil {
            guard model.tabGroups.groups.count < 16,
                  model.tabGroups.groups.first(where: { $0.id == id })?.tabIDs != [source] else { return nil }
        }
        return (id, direction, direction.map { half(frame, direction: $0) } ?? frame)
    }

    private func half(_ frame: CGRect, direction: SplitDirection) -> CGRect {
        switch direction {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .up: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .down: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
    func clearPreview() { preview.isHidden = true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let target = target(sender) else { clearPreview(); return [] }
        preview.frame = target.rect.insetBy(dx: 2, dy: 2)
        preview.isHidden = false
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearPreview() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearPreview() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { target(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearPreview() }
        guard let id = draggedSessionID(sender), let target = target(sender) else { return false }
        if let group = target.group { model.moveSessionTab(id, to: group, direction: target.direction) }
        else if let direction = target.direction { model.moveSessionTabToWorkspaceEdge(id, direction: direction) }
        return true
    }
}

private final class DropPreviewView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 2
        outline.stroke()
    }
}

struct GroupTabStrip: NSViewRepresentable {
    let model: AppModel
    let groupID: UUID

    func makeNSView(context: Context) -> GroupTabStripView { GroupTabStripView() }
    func updateNSView(_ view: GroupTabStripView, context: Context) {
        let group = model.tabGroups.groups.first { $0.id == groupID }
        view.model = model
        view.groupID = groupID
        view.reload(tabs: (group?.tabIDs ?? []).compactMap { id in model.tabs.first { $0.id == id } }, selected: group?.selectedTabID)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GroupTabStripView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 200, height: 34)
    }
}

/// Drawing, hit testing and insertion share a single AppKit document coordinate space.
final class GroupTabStripView: NSScrollView {
    weak var model: AppModel?
    var groupID = UUID()
    private let strip = SessionTabDocumentView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        documentView = strip
        strip.owner = self
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Created in code") }

    func reload(tabs: [WorkspaceTab], selected: UUID?) {
        let oldSelection = strip.selectedID
        strip.tabs = tabs
        strip.selectedID = selected
        strip.rebuildFrames(minimumWidth: contentSize.width)
        if oldSelection != selected, let selected, let rect = strip.tabFrames[selected] {
            strip.scrollToVisible(rect)
        }
    }
    override func layout() {
        super.layout()
        strip.rebuildFrames(minimumWidth: contentSize.width)
    }
    override func accessibilityChildren() -> [Any]? { [strip] }
}

private final class SessionTabDocumentView: NSView, NSDraggingSource {
    weak var owner: GroupTabStripView?
    var tabs: [WorkspaceTab] = []
    var selectedID: UUID?
    var tabFrames: [UUID: CGRect] = [:]
    private var down: (id: UUID, point: CGPoint, close: Bool)?
    private var caret: CGFloat?
    private var dragInProgress = false
    private var closeButtons: [UUID: SessionTabCloseButton] = [:]
    private weak var dragWorkspace: WorkspaceDropHostView?
    private var workspace: WorkspaceDropHostView? {
        var view = superview
        while let candidate = view {
            if let host = candidate as? WorkspaceDropHostView { return host }
            view = candidate.superview
        }
        return nil
    }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([tabPasteboardType])
        setAccessibilityRole(.tabGroup)
        setAccessibilityElement(true)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Created in code") }

    func rebuildFrames(minimumWidth: CGFloat) {
        let validIDs = Set(tabs.map(\.id))
        for id in Array(closeButtons.keys) where !validIDs.contains(id) {
            closeButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        var x: CGFloat = 4
        tabFrames = [:]
        for tab in tabs {
            let textWidth = (tab.controller.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            let width = min(220, max(90, textWidth + 48))
            tabFrames[tab.id] = CGRect(x: x, y: 4, width: width, height: 26)
            let button = closeButtons[tab.id] ?? SessionTabCloseButton()
            button.tabID = tab.id
            button.target = self
            button.action = #selector(closeTabButton(_:))
            button.frame = closeRect(tabFrames[tab.id]!)
            button.toolTip = String(localized: "Close Tab")
            button.setAccessibilityLabel(String(localized: "Close Tab") + " — " + tab.controller.title)
            if button.superview !== self { addSubview(button) }
            closeButtons[tab.id] = button
            x += width + 4
        }
        setFrameSize(CGSize(width: max(minimumWidth, x), height: 34))
        needsDisplay = true
    }
    private func closeRect(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - 23, y: frame.minY + 3, width: 20, height: 20)
    }

    @objc private func closeTabButton(_ sender: SessionTabCloseButton) {
        down = nil
        owner?.model?.requestCloseTab(sender.tabID)
    }

    override func accessibilityChildren() -> [Any]? {
        guard let window else { return [] }
        return tabs.enumerated().flatMap { index, tab -> [Any] in
            guard let rect = tabFrames[tab.id], rect.intersects(visibleRect) else { return [] }
            let select = TabAccessibilityAction { [weak self] in
                self?.owner?.model?.selectTab(tab.id)
                self?.owner?.model?.focusActiveTerminal()
            }
            select.setAccessibilityParent(self)
            select.setAccessibilityRole(.radioButton)
            select.setAccessibilityLabel("\(tab.controller.title), Tab \(index + 1)")
            select.setAccessibilityIdentifier("session-tab-\(tab.id)")
            select.setAccessibilityValue(tab.id == selectedID)
            select.setAccessibilityFrame(window.convertToScreen(convert(rect.intersection(visibleRect), to: nil)))
            return [select] + (closeButtons[tab.id].map { [$0] } ?? [])
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        for tab in tabs {
            guard let rect = tabFrames[tab.id] else { continue }
            if tab.id == selectedID {
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let color: NSColor = tab.state == .connected ? .systemGreen : tab.state == .connecting ? .systemYellow : .secondaryLabelColor
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.minX + 8, y: rect.midY - 3, width: 6, height: 6)).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (tab.controller.title as NSString).draw(in: CGRect(x: rect.minX + 20, y: rect.minY + 5, width: rect.width - 46, height: 18), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ])
        }
        if let caret {
            NSColor.controlAccentColor.setFill()
            CGRect(x: caret - 1, y: 3, width: 2, height: 28).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        guard let id = TabStripHitTest.tab(at: point, order: tabs.map(\.id), frames: tabFrames), let rect = tabFrames[id] else { return }
        down = (id, point, closeRect(rect).contains(point))
    }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        guard let down, !dragInProgress, let rect = tabFrames[down.id] else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard rect.contains(point) else { return }
        if down.close {
            if closeRect(rect).contains(point) { owner?.model?.requestCloseTab(down.id) }
        } else {
            owner?.model?.selectTab(down.id)
            owner?.model?.focusActiveTerminal()
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, !down.close, !dragInProgress, let rect = tabFrames[down.id] else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - down.point.x, point.y - down.point.y) >= 5 else { return }
        let pasteboard = NSPasteboardItem()
        pasteboard.setData(Data(("termeow-tab:" + down.id.uuidString).utf8), forType: tabPasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let preview = NSImage(size: rect.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: bitmap)
            preview.addRepresentation(bitmap)
        }
        let draggingFrame = rect.offsetBy(dx: point.x - down.point.x, dy: point.y - down.point.y)
        item.setDraggingFrame(draggingFrame, contents: preview)
        dragInProgress = true
        dragWorkspace = workspace
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        down = nil
        dragInProgress = false
        caret = nil
        needsDisplay = true
        dragWorkspace?.clearPreview()
        dragWorkspace = nil
    }
    private func sourceID(_ sender: NSDraggingInfo) -> UUID? {
        draggedSessionID(sender)
    }
    private func insertion(_ sender: NSDraggingInfo, source: UUID) -> (before: UUID?, x: CGFloat) {
        let point = convert(sender.draggingLocation, from: nil)
        let target = TabStripHitTest.insertion(at: point.x, order: tabs.map(\.id), frames: tabFrames, excluding: source)
        return (target.before, target.markerX)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let workspace, workspace.outerEdge(at: sender.draggingLocation) != nil {
            caret = nil
            needsDisplay = true
            return workspace.draggingUpdated(sender)
        }
        workspace?.clearPreview()
        guard let source = sourceID(sender) else { return [] }
        if let event = NSApp.currentEvent { autoscroll(with: event) }
        caret = insertion(sender, source: source).x
        needsDisplay = true
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { caret = nil; needsDisplay = true; workspace?.clearPreview() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { sourceID(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { caret = nil; needsDisplay = true }
        if let workspace, workspace.outerEdge(at: sender.draggingLocation) != nil { return workspace.performDragOperation(sender) }
        guard let source = sourceID(sender), let owner, let model = owner.model else { return false }
        model.moveSessionTab(source, to: owner.groupID, before: insertion(sender, source: source).before)
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let tab = tabs.first(where: { tabFrames[$0.id]?.contains(point) == true }), let owner, let model = owner.model else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            let item = TabMenuCommand(title: title, handler: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(String(localized: "Connect"), enabled: tab.controller.canReconnect) { model.reconnectTab(tab.id) }
        add(String(localized: "Disconnect"), enabled: tab.controller.canDisconnect) { model.disconnectTab(tab.id) }
        add(String(localized: "Duplicate Connection")) { model.selectTab(tab.id); model.duplicateTab(tab.id) }
        add(String(localized: "Open SFTP")) { model.openSFTP(tab.controller.profile) }
        add("Port Forwarding…") { model.forwardingController = tab.controller }
        menu.addItem(.separator())
        let newGroup = NSMenuItem(title: String(localized: "Move to New Tab Group"), action: nil, keyEquivalent: "")
        let directions = NSMenu()
        directions.autoenablesItems = false
        for (direction, title) in [(SplitDirection.left, String(localized: "Left")), (.right, String(localized: "Right")), (.up, String(localized: "Above")), (.down, String(localized: "Below"))] {
            let item = TabMenuCommand(title: title) { model.moveSessionTab(tab.id, to: owner.groupID, direction: direction) }
            item.isEnabled = tabs.count > 1 && model.tabGroups.groups.count < 16
            directions.addItem(item)
        }
        newGroup.submenu = directions
        menu.addItem(newGroup)
        let move = NSMenuItem(title: String(localized: "Move to Tab Group"), action: nil, keyEquivalent: "")
        let targets = NSMenu()
        targets.autoenablesItems = false
        for (index, id) in model.tabGroups.layout.paneIDs.enumerated() {
            let item = TabMenuCommand(title: "Group \(index + 1)") { model.moveSessionTab(tab.id, to: id) }
            item.isEnabled = id != owner.groupID
            targets.addItem(item)
        }
        move.submenu = targets
        menu.addItem(move)
        menu.addItem(.separator())
        add(String(localized: "Close Tab")) { model.requestCloseTab(tab.id) }
        add(String(localized: "Close Other Tabs"), enabled: tabs.count > 1) { model.closeOtherTabs(keeping: tab.id) }
        add(String(localized: "Close Tabs to the Right"), enabled: model.hasTabsToRight(of: tab.id)) { model.closeTabsToRight(of: tab.id) }
        return menu
    }
}

private final class SessionTabCloseButton: NSButton {
    var tabID = UUID()
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close Tab"))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        isBordered = false
        setButtonType(.momentaryChange)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Created in code") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class TabAccessibilityAction: NSAccessibilityElement {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action; super.init() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

private final class TabMenuCommand: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Created in code") }
    @objc private func invoke() { handler() }
}
