import AppKit
import SwiftUI
import TermeowKit

struct TerminalContainerView: View {
    @Environment(AppModel.self) private var model
    var controller: ConnectionController

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.findBarVisible {
                FindBar()
            }
            TerminalViewRepresentable(
                controller: controller,
                typography: model.typography,
                colorSchemeID: model.colorSchemeID
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        applyAppearance(to: host)
        DispatchQueue.main.async {
            host.terminal.window?.makeFirstResponder(host.terminal)
        }
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.attach(controller.hostedTerminal())
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

    private func applyFrame() {
        let size = bounds.size
        guard size.width >= 80, size.height >= 40 else { return }
        if terminal.frame != bounds {
            terminal.frame = bounds
        }
    }
}
