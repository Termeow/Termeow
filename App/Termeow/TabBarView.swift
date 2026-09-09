import AppKit
import SwiftUI
import TermeowKit

struct TabBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NativeTabBar(items: items, selectedID: model.selectedTabID, actions: actions)
            .frame(height: 36)
            .background(.ultraThinMaterial)
    }

    private var items: [TabBarItem] {
        model.tabs.map { tab in
            TabBarItem(
                id: tab.id,
                title: tab.controller.title,
                state: tab.state,
                canReconnect: tab.controller.canReconnect,
                canDisconnect: tab.controller.canDisconnect,
                canMoveLeft: model.canMoveTab(tab.id, by: -1),
                canMoveRight: model.canMoveTab(tab.id, by: 1),
                hasTabsToRight: model.hasTabsToRight(of: tab.id),
                tabCount: model.tabs.count,
                paneCount: tab.paneCount
            )
        }
    }

    private var actions: TabBarActions {
        TabBarActions(
            onSelect: { model.selectTab($0) },
            onClose: { model.requestCloseTab($0) },
            onReorder: { model.reorderTab($0, over: $1) },
            onConnect: { model.reconnectTab($0) },
            onDisconnect: { model.disconnectTab($0) },
            onDuplicate: { model.duplicateTab($0) },
            onOpenSFTP: { id in
                guard let tab = model.tabs.first(where: { $0.id == id }) else { return }
                model.openSFTP(tab.controller.profile)
            },
            onSplit: { model.splitPane(in: $0, axis: $1) },
            onClosePane: { model.requestClosePane(in: $0) },
            onMove: { model.moveTab($0, by: $1) },
            onCloseOthers: { model.closeOtherTabs(keeping: $0) },
            onCloseToRight: { model.closeTabsToRight(of: $0) }
        )
    }
}

private struct TabBarItem: Equatable {
    var id: UUID
    var title: String
    var state: SSHConnectionState
    var canReconnect: Bool
    var canDisconnect: Bool
    var canMoveLeft: Bool
    var canMoveRight: Bool
    var hasTabsToRight: Bool
    var tabCount: Int
    var paneCount: Int
}

private struct TabBarActions {
    var onSelect: (UUID) -> Void
    var onClose: (UUID) -> Void
    var onReorder: (UUID, UUID) -> Void
    var onConnect: (UUID) -> Void
    var onDisconnect: (UUID) -> Void
    var onDuplicate: (UUID) -> Void
    var onOpenSFTP: (UUID) -> Void
    var onSplit: (UUID, PaneSplitAxis) -> Void
    var onClosePane: (UUID) -> Void
    var onMove: (UUID, Int) -> Void
    var onCloseOthers: (UUID) -> Void
    var onCloseToRight: (UUID) -> Void
}

private struct NativeTabBar: NSViewRepresentable {
    var items: [TabBarItem]
    var selectedID: UUID?
    var actions: TabBarActions

    func makeNSView(context: Context) -> TabBarHostView {
        TabBarHostView()
    }

    func updateNSView(_ nsView: TabBarHostView, context: Context) {
        nsView.actions = actions
        nsView.reload(items: items, selectedID: selectedID)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TabBarHostView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 200, height: 36)
    }
}

private final class TabBarHostView: NSView {
    var actions = TabBarActions(
        onSelect: { _ in },
        onClose: { _ in },
        onReorder: { _, _ in },
        onConnect: { _ in },
        onDisconnect: { _ in },
        onDuplicate: { _ in },
        onOpenSFTP: { _ in },
        onSplit: { _, _ in },
        onClosePane: { _ in },
        onMove: { _, _ in },
        onCloseOthers: { _ in },
        onCloseToRight: { _ in }
    )

    private let scrollView = TabBarScrollView()
    private let documentView = FlippedView()
    private let slotPlaceholder: PassthroughView = {
        let view = PassthroughView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 11
        view.layer?.borderWidth = 1.5
        view.isHidden = true
        return view
    }()
    private let insertionCaret: PassthroughView = {
        let view = PassthroughView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 2
        view.isHidden = true
        return view
    }()
    private var chips: [UUID: TabChipNSView] = [:]
    private var items: [TabBarItem] = []
    private var selectedID: UUID?
    private var draggingID: UUID?
    private var dropTargetID: UUID?
    private var laidDropTargetID: UUID?
    private var mouseMonitor: Any?
    private var trackingID: UUID?
    private var dragStart: NSPoint?
    private var grabOffsetX: CGFloat = 0
    private var dragPointerX: CGFloat = 0
    private var isShowingContextMenu = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
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
        layoutChips()
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
        guard let chip = chip(atWindowPoint: event.locationInWindow) else { return true }
        isShowingContextMenu = true
        // ponytail: pop on the next turn so the monitor is not nested inside the menu
        DispatchQueue.main.async { [weak self, weak chip] in
            chip?.popContextMenu(event)
            self?.isShowingContextMenu = false
        }
        return true
    }

    private func chip(atWindowPoint point: NSPoint) -> TabChipNSView? {
        let documentPoint = documentView.convert(point, from: nil)
        for item in items.reversed() {
            if let chip = chips[item.id], chip.frame.contains(documentPoint) {
                return chip
            }
        }
        return nil
    }

    private func handlePrimaryDown(_ event: NSEvent) -> Bool {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return false }

        let documentPoint = documentView.convert(event.locationInWindow, from: nil)
        for item in items.reversed() {
            guard let chip = chips[item.id], chip.frame.contains(documentPoint) else { continue }
            if chip.hitClose(windowPoint: event.locationInWindow) {
                actions.onClose(item.id)
                return true
            }
            trackingID = item.id
            dragStart = event.locationInWindow
            actions.onSelect(item.id)
            return true
        }
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

        let distance = hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y)
        let documentX = documentView.convert(event.locationInWindow, from: nil).x
        if draggingID == nil {
            guard distance >= 10 else { return }
            beginDrag(of: trackingID, documentX: documentX)
        } else {
            updateDrag(of: trackingID, documentX: documentX)
        }
    }

    func reload(items: [TabBarItem], selectedID: UUID?) {
        self.items = items
        self.selectedID = selectedID
        let ids = Set(items.map(\.id))
        for (id, chip) in chips where !ids.contains(id) {
            chip.removeFromSuperview()
            chips.removeValue(forKey: id)
        }
        for item in items {
            let chip = chips[item.id] ?? {
                let created = TabChipNSView()
                created.host = self
                created.wantsLayer = true
                created.layer?.masksToBounds = false
                documentView.addSubview(created, positioned: .below, relativeTo: insertionCaret)
                chips[item.id] = created
                return created
            }()
            chip.item = item
            chip.selected = item.id == selectedID
            chip.dragging = item.id == draggingID
            chip.needsDisplay = true
        }
        layoutChips()
    }

    func beginDrag(of id: UUID, documentX: CGFloat) {
        draggingID = id
        dragPointerX = documentX
        if let chip = chips[id] {
            grabOffsetX = documentX - chip.frame.minX
            documentView.addSubview(chip, positioned: .above, relativeTo: insertionCaret)
        }
        laidDropTargetID = nil
        updateDropTarget(documentX: documentX)
        reload(items: items, selectedID: selectedID)
    }

    func updateDrag(of id: UUID, documentX: CGFloat) {
        draggingID = id
        dragPointerX = documentX
        updateDropTarget(documentX: documentX)
        reload(items: items, selectedID: selectedID)
    }

    func finishDrag() {
        let sourceID = draggingID
        let targetID = dropTargetID
        draggingID = nil
        dropTargetID = nil
        laidDropTargetID = nil
        grabOffsetX = 0
        insertionCaret.isHidden = true
        slotPlaceholder.isHidden = true
        reload(items: items, selectedID: selectedID)
        guard let sourceID, let targetID else { return }
        actions.onReorder(sourceID, targetID)
    }

    private func updateDropTarget(documentX: CGFloat) {
        guard let sourceID = draggingID,
              let sourceIndex = items.firstIndex(where: { $0.id == sourceID }) else {
            dropTargetID = nil
            return
        }
        let frames = restingFrames()
        guard let sourceFrame = frames[sourceID] else {
            dropTargetID = nil
            return
        }
        dropTargetID = TabReorder.targetID(
            sourceIndex: sourceIndex,
            sourceFrame: sourceFrame,
            pointerX: documentX,
            orderedIDs: items.map(\.id),
            frames: frames
        )
    }

    private func restingFrames() -> [UUID: CGRect] {
        var x: CGFloat = 10
        let chipHeight: CGFloat = 22
        let y = max((bounds.height - chipHeight) / 2, 0)
        var frames: [UUID: CGRect] = [:]
        for item in items {
            guard let chip = chips[item.id] else { continue }
            let width = chip.preferredWidth
            frames[item.id] = CGRect(x: x, y: y, width: width, height: chipHeight)
            x += width + 6
        }
        return frames
    }

    private func layoutChips() {
        let chipHeight: CGFloat = 22
        let y = max((bounds.height - chipHeight) / 2, 0)
        let ids = items.map(\.id)
        let order = draggingID.map { TabReorder.previewIDs(ids, moving: $0, over: dropTargetID) } ?? ids
        let animateNeighbors = draggingID != nil && dropTargetID != laidDropTargetID
        laidDropTargetID = dropTargetID

        var x: CGFloat = 10
        var slot: CGRect?
        var neighborFrames: [(TabChipNSView, CGRect)] = []
        for id in order {
            guard let chip = chips[id] else { continue }
            let width = chip.preferredWidth
            let rest = CGRect(x: x, y: y, width: width, height: chipHeight)
            if id == draggingID {
                slot = rest
                chip.layer?.zPosition = 10
                chip.frame = CGRect(x: dragPointerX - grabOffsetX, y: y - 3, width: width, height: chipHeight)
            } else {
                chip.layer?.zPosition = 0
                neighborFrames.append((chip, rest))
            }
            x += width + 6
        }

        let applyNeighborsAndMarkers = { (animated: Bool) in
            for (chip, frame) in neighborFrames {
                if animated {
                    chip.animator().frame = frame
                } else {
                    chip.frame = frame
                }
            }
            self.updateDragMarkers(slot: slot, animated: animated)
        }
        if animateNeighbors {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                applyNeighborsAndMarkers(true)
            }
        } else {
            applyNeighborsAndMarkers(false)
        }

        let width = max(x + 4, bounds.width)
        documentView.frame = CGRect(x: 0, y: 0, width: width, height: max(bounds.height, 36))
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

        let caret = CGRect(x: slot.minX - 2, y: slot.midY - 10, width: 4, height: 20)
        let showCaret = dropTargetID != nil
        if showCaret, insertionCaret.isHidden {
            insertionCaret.frame = caret
            insertionCaret.isHidden = false
        } else if showCaret {
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
}

private final class TabBarScrollView: NSScrollView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PassthroughView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class TabChipNSView: NSView {
    weak var host: TabBarHostView?
    var item = TabBarItem(
        id: UUID(),
        title: "",
        state: .disconnected,
        canReconnect: true,
        canDisconnect: false,
        canMoveLeft: false,
        canMoveRight: false,
        hasTabsToRight: false,
        tabCount: 1,
        paneCount: 1
    )
    var selected = false
    var dragging = false {
        didSet { applyDragChrome() }
    }

    private let closeButton = TabCloseNSButton()
    private let titleFont = NSFont.systemFont(ofSize: 13)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleNone
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityLabel(String(localized: "Close Tab"))
        closeButton.toolTip = String(localized: "Close Tab")
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var preferredWidth: CGFloat {
        let titleWidth = ceil((item.title as NSString).size(withAttributes: [.font: titleFont]).width)
        return min(240, max(72, 10 + 7 + 6 + titleWidth + 6 + 22 + 4))
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let closePoint = convert(point, to: closeButton)
        if closeButton.bounds.contains(closePoint) { return closeButton }
        return self
    }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: bounds.width - 26, y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        setAccessibilityLabel(item.title)
        setAccessibilitySelected(selected)

        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if dragging {
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            capsule.fill()
            NSColor.controlAccentColor.setStroke()
            capsule.lineWidth = 2
            capsule.stroke()
        } else if selected {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
            capsule.fill()
        }

        let dot = NSRect(x: 10, y: (bounds.height - 7) / 2, width: 7, height: 7)
        statusColor.setFill()
        NSBezierPath(ovalIn: dot).fill()

        let titleHeight = titleFont.boundingRectForFont.height
        let titleRect = NSRect(
            x: 23,
            y: (bounds.height - titleHeight) / 2,
            width: max(closeButton.frame.minX - 29, 0),
            height: titleHeight
        )
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (item.title as NSString).draw(
            in: titleRect,
            withAttributes: [
                .font: titleFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        )
    }

    private func applyDragChrome() {
        wantsLayer = true
        layer?.masksToBounds = false
        if dragging {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.45
            layer?.shadowRadius = 8
            layer?.shadowOffset = CGSize(width: 0, height: 3)
        } else {
            layer?.shadowOpacity = 0
            layer?.shadowRadius = 0
        }
    }

    func hitClose(windowPoint: NSPoint) -> Bool {
        closeButton.frame.contains(convert(windowPoint, from: nil))
    }

    func popContextMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        host?.actions.onSelect(item.id)
        return true
    }

    private var statusColor: NSColor {
        switch item.state {
        case .connected: .systemGreen
        case .connecting: .systemYellow
        case .failed: .systemRed
        case .disconnected: .secondaryLabelColor
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let connectTitle = item.state == .disconnected
            ? String(localized: "Connect")
            : String(localized: "Reconnect")
        menu.addItem(menuItem(connectTitle, #selector(connectTab), enabled: item.canReconnect))
        menu.addItem(menuItem(String(localized: "Disconnect"), #selector(disconnectTab), enabled: item.canDisconnect))
        menu.addItem(menuItem(String(localized: "Duplicate Tab"), #selector(duplicateTab)))
        menu.addItem(menuItem(String(localized: "Open SFTP"), #selector(openSFTP)))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Split Pane Vertically"), #selector(splitVertically)))
        menu.addItem(menuItem(String(localized: "Split Pane Horizontally"), #selector(splitHorizontally)))
        menu.addItem(menuItem(String(localized: "Close Active Pane"), #selector(closePane), enabled: item.paneCount > 1))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Move Tab Left"), #selector(moveTabLeft), enabled: item.canMoveLeft))
        menu.addItem(menuItem(String(localized: "Move Tab Right"), #selector(moveTabRight), enabled: item.canMoveRight))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Close Tab"), #selector(closeTab)))
        menu.addItem(menuItem(String(localized: "Close Other Tabs"), #selector(closeOthers), enabled: item.tabCount > 1))
        menu.addItem(menuItem(String(localized: "Close Tabs to the Right"), #selector(closeToRight), enabled: item.hasTabsToRight))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func closeTab() { host?.actions.onClose(item.id) }
    @objc private func connectTab() { host?.actions.onConnect(item.id) }
    @objc private func disconnectTab() { host?.actions.onDisconnect(item.id) }
    @objc private func duplicateTab() { host?.actions.onDuplicate(item.id) }
    @objc private func openSFTP() { host?.actions.onOpenSFTP(item.id) }
    @objc private func splitVertically() { host?.actions.onSplit(item.id, .vertical) }
    @objc private func splitHorizontally() { host?.actions.onSplit(item.id, .horizontal) }
    @objc private func closePane() { host?.actions.onClosePane(item.id) }
    @objc private func moveTabLeft() { host?.actions.onMove(item.id, -1) }
    @objc private func moveTabRight() { host?.actions.onMove(item.id, 1) }
    @objc private func closeOthers() { host?.actions.onCloseOthers(item.id) }
    @objc private func closeToRight() { host?.actions.onCloseToRight(item.id) }
}

private final class TabCloseNSButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}
