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
                FindBar(controller: controller, representable: representable)
            }
            TerminalViewRepresentable(controller: controller, box: representable)
                .background(Color.black)
        }
    }
}

struct FindBar: View {
    @Environment(AppModel.self) private var model
    var controller: ConnectionController
    var representable: TerminalViewBox
    @State private var hits: [TerminalSearchHit] = []
    @State private var index = 0

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            TextField("Find", text: $model.findQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }
            Toggle("Case sensitive", isOn: $model.findCaseSensitive)
                .toggleStyle(.checkbox)
            Text(hits.isEmpty ? "No results" : "\(index + 1)/\(hits.count)")
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Button("Previous") { move(-1) }
            Button("Next") { move(1) }
            Button("Done") {
                model.findBarVisible = false
                representable.view?.searchHits = []
                representable.view?.activeHitIndex = nil
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .onChange(of: model.findQuery) { _, _ in runSearch() }
        .onChange(of: model.findCaseSensitive) { _, _ in runSearch() }
        .onAppear { runSearch() }
    }

    private func runSearch() {
        hits = controller.engine.search(query: model.findQuery, caseSensitive: model.findCaseSensitive)
        index = hits.isEmpty ? 0 : min(index, hits.count - 1)
        representable.view?.searchHits = hits
        representable.view?.activeHitIndex = hits.isEmpty ? nil : index
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        index = (index + delta + hits.count) % hits.count
        representable.view?.activeHitIndex = index
    }
}

@Observable
final class TerminalViewBox {
    weak var view: TerminalRendererView?
}

struct TerminalViewRepresentable: NSViewRepresentable {
    var controller: ConnectionController
    var box: TerminalViewBox

    func makeNSView(context: Context) -> TerminalRendererView {
        let view = TerminalRendererView(engine: controller.engine)
        box.view = view
        view.onInput = { data in
            controller.sendRemoteOnly(data)
        }
        view.onResize = { cols, rows in
            controller.noteSize(cols: cols, rows: rows)
        }
        view.onPasteConfirm = { text in
            confirmPaste(text, view: view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalRendererView, context: Context) {
        nsView.engine = controller.engine
        box.view = nsView
    }

    private func confirmPaste(_ text: String, view: TerminalRendererView) {
        let alert = NSAlert()
        alert.messageText = "Paste a large clipboard?"
        alert.informativeText = "This paste is large or contains many lines. Send it to the remote session?"
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            view.pasteConfirmed(text)
        }
    }
}
