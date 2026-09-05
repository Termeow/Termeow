import AppKit
import SwiftUI
import TermeowKit

struct TerminalContainerView: View {
    @Environment(AppModel.self) private var model
    var controller: ConnectionController
    @State private var representable = TerminalViewBox()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.findBarVisible {
                FindBar(representable: representable)
            }
            TerminalViewRepresentable(controller: controller, box: representable)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FindBar: View {
    @Environment(AppModel.self) private var model
    var representable: TerminalViewBox
    @State private var matchIndex = 0
    @State private var matchTotal = 0

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            TextField("Find", text: $model.findQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch(forward: true) }
            Toggle("Case sensitive", isOn: $model.findCaseSensitive)
                .toggleStyle(.checkbox)
            Text(matchTotal == 0 ? "No results" : "\(matchIndex)/\(matchTotal)")
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Button("Previous") { runSearch(forward: false) }
            Button("Next") { runSearch(forward: true) }
            Button("Done") {
                model.findBarVisible = false
                representable.view?.dismissSearch()
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .onChange(of: model.findQuery) { _, _ in runSearch(forward: true) }
        .onChange(of: model.findCaseSensitive) { _, _ in runSearch(forward: true) }
        .onAppear { runSearch(forward: true) }
    }

    private func runSearch(forward: Bool) {
        guard let view = representable.view else {
            matchIndex = 0
            matchTotal = 0
            return
        }
        if model.findQuery.isEmpty {
            view.dismissSearch()
            matchIndex = 0
            matchTotal = 0
            return
        }
        if forward {
            _ = view.findForward(model.findQuery, caseSensitive: model.findCaseSensitive)
        } else {
            _ = view.findBackward(model.findQuery, caseSensitive: model.findCaseSensitive)
        }
        let summary = view.searchSummary(model.findQuery, caseSensitive: model.findCaseSensitive)
        matchIndex = summary.index
        matchTotal = summary.total
    }
}

@Observable
final class TerminalViewBox {
    weak var view: SSHTerminalView?
}

struct TerminalViewRepresentable: NSViewRepresentable {
    var controller: ConnectionController
    var box: TerminalViewBox

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView(terminal: controller.hostedTerminal())
        box.view = host.terminal
        DispatchQueue.main.async {
            host.terminal.window?.makeFirstResponder(host.terminal)
        }
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.attach(controller.hostedTerminal())
        box.view = host.terminal
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: ()) {
        host.detach()
    }
}

final class TerminalHostView: NSView {
    private(set) var terminal: SSHTerminalView

    init(terminal: SSHTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TerminalColorScheme.default.background.cgColor
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

    func detach() {
        terminal.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        applyFrame()
    }

    private func applyFrame() {
        let size = bounds.size
        guard size.width >= 80, size.height >= 40 else { return }
        if terminal.frame != bounds {
            terminal.frame = bounds
        }
    }
}
