import AppKit
@preconcurrency import SwiftTerm

public final class SSHTerminalView: TerminalView {
    public var onSend: ((Data) -> Void)? {
        get { host.onSend }
        set { host.onSend = newValue }
    }

    public var onSizeChanged: ((Int, Int) -> Void)? {
        get { host.onSizeChanged }
        set { host.onSizeChanged = newValue }
    }

    private let host = Host()

    public init() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        super.init(frame: .zero, font: font)
        terminalDelegate = host
        applyAppearance()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("SSHTerminalView is created in code")
    }

    // SwiftTerm documents feed as safe to call from a background thread.
    nonisolated public func feedOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        feed(byteArray: [UInt8](data)[...])
    }

    public func findForward(_ query: String, caseSensitive: Bool) -> Bool {
        guard !query.isEmpty else {
            clearSearch()
            return false
        }
        return findNext(query, options: SearchOptions(caseSensitive: caseSensitive))
    }

    public func findBackward(_ query: String, caseSensitive: Bool) -> Bool {
        guard !query.isEmpty else {
            clearSearch()
            return false
        }
        return findPrevious(query, options: SearchOptions(caseSensitive: caseSensitive))
    }

    public func searchSummary(_ query: String, caseSensitive: Bool) -> (index: Int, total: Int) {
        guard !query.isEmpty else { return (0, 0) }
        return searchMatchSummary(query, options: SearchOptions(caseSensitive: caseSensitive))
    }

    public func dismissSearch() {
        clearSearch()
    }

    private func applyAppearance() {
        let scheme = TerminalColorScheme.default
        appearance = NSAppearance(named: .darkAqua)
        nativeForegroundColor = scheme.foreground
        nativeBackgroundColor = scheme.background
        caretColor = scheme.cursor
        selectedTextBackgroundColor = scheme.selection
        installColors(scheme.ansi.map { Color(nsColor: $0) })
    }
}

private final class Host: TerminalViewDelegate, @unchecked Sendable {
    var onSend: ((Data) -> Void)?
    var onSizeChanged: ((Int, Int) -> Void)?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols >= 2, newRows >= 1 else { return }
        onSizeChanged?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onSend?(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}

public final class TerminalInbound: @unchecked Sendable {
    private let lock = NSLock()
    private weak var view: SSHTerminalView?
    private var pending = Data()

    public init() {}

    public func attach(_ view: SSHTerminalView?) {
        lock.lock()
        self.view = view
        let flush = pending
        pending = Data()
        lock.unlock()
        if let view, !flush.isEmpty {
            view.feedOutput(flush)
        }
    }

    public func feed(_ data: Data) {
        lock.lock()
        if let view {
            lock.unlock()
            view.feedOutput(data)
            return
        }
        pending.append(data)
        lock.unlock()
    }
}
