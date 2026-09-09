import AppKit
import SwiftUI
import TermeowKit

struct TerminalWorkspaceView: View {
    @Environment(AppModel.self) private var model
    var tabID: WorkspaceTab.ID

    var body: some View {
        VStack(spacing: 0) {
            if model.findBarVisible {
                FindBar()
            }
            if let tab = model.tabs.first(where: { $0.id == tabID }) {
                PaneLayoutView(tabID: tabID, layout: tab.layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct PaneLayoutView: View {
    var tabID: WorkspaceTab.ID
    var layout: PaneLayout

    var body: some View {
        content
    }

    private var content: AnyView {
        switch layout {
        case .leaf(let paneID):
            AnyView(TerminalPaneView(tabID: tabID, paneID: paneID))
        case .split(.vertical, let first, let second):
            AnyView(
                HSplitView {
                    PaneLayoutView(tabID: tabID, layout: first)
                    PaneLayoutView(tabID: tabID, layout: second)
                }
            )
        case .split(.horizontal, let first, let second):
            AnyView(
                VSplitView {
                    PaneLayoutView(tabID: tabID, layout: first)
                    PaneLayoutView(tabID: tabID, layout: second)
                }
            )
        }
    }
}

private struct TerminalPaneView: View {
    @Environment(AppModel.self) private var model
    var tabID: WorkspaceTab.ID
    var paneID: UUID

    var body: some View {
        if let controller = model.controller(in: tabID, paneID: paneID) {
            VStack(spacing: 0) {
                if paneCount > 1 {
                    paneHeader(controller: controller)
                }
                TerminalContainerView(controller: controller)
                    .id(controller.id)
            }
            .overlay {
                Rectangle()
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var isSelected: Bool {
        model.isSelectedPane(tabID: tabID, paneID: paneID)
    }

    private var paneCount: Int {
        model.tabs.first(where: { $0.id == tabID })?.paneCount ?? 0
    }

    private func paneHeader(controller: ConnectionController) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor(controller.state))
                .frame(width: 7, height: 7)
            Text(controller.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Split Pane Vertically", systemImage: "rectangle.split.2x1") {
                selectPane()
                model.splitPane(in: tabID, axis: .vertical)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Split Pane Vertically")
            Button("Split Pane Horizontally", systemImage: "rectangle.split.1x2") {
                selectPane()
                model.splitPane(in: tabID, axis: .horizontal)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Split Pane Horizontally")
            Button("Close Pane", systemImage: "xmark") {
                selectPane()
                model.requestClosePane(in: tabID)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close Pane")
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(isSelected ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture(perform: activatePane)
    }

    private func activatePane() {
        selectPane()
        DispatchQueue.main.async {
            model.controller(in: tabID, paneID: paneID)?.focusTerminal()
        }
    }

    private func selectPane() {
        model.focusPane(paneID)
    }

    private func statusColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

struct TerminalContainerView: View {
    @Environment(AppModel.self) private var model
    var controller: ConnectionController

    var body: some View {
        TerminalViewRepresentable(
            controller: controller,
            typography: model.typography,
            colorSchemeID: model.colorSchemeID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView(terminal: controller.hostedTerminal())
        host.onFocus = { controller.noteFocus() }
        applyAppearance(to: host)
        DispatchQueue.main.async {
            host.terminal.window?.makeFirstResponder(host.terminal)
        }
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
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
            self.terminal.removeFromSuperview()
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
        terminal.removeFromSuperview()
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
        let size = bounds.size
        guard size.width >= 80, size.height >= 40 else { return }
        if terminal.frame != bounds {
            terminal.frame = bounds
        }
    }
}
