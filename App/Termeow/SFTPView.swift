import AppKit
import Observation
import SwiftUI
import TermeowKit

enum SFTPBrowserSide {
    case local
    case remote
}

struct LocalFileItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
    let size: UInt64?
    let modificationDate: Date?
}

private enum PendingSFTPTransfer {
    case upload([URL])
    case download([SFTPItem])
}

@MainActor
@Observable
final class SFTPBrowserModel {
    let profile: SessionProfile

    var localCurrentURL: URL
    var localPathInput: String
    var localItems: [LocalFileItem] = []
    var selectedLocalItemIDs: Set<LocalFileItem.ID> = []
    var localSearchText = ""
    var localBackHistory: [URL] = []
    var localForwardHistory: [URL] = []

    var remoteCurrentPath = ""
    var remotePathInput = ""
    var remoteItems: [SFTPItem] = []
    var selectedRemoteItemIDs: Set<SFTPItem.ID> = []
    var remoteSearchText = ""
    var remoteBackHistory: [String] = []
    var remoteForwardHistory: [String] = []

    var showsHiddenFiles = false
    var isConnected = false
    var isBusy = false
    var statusMessage = ""
    var errorMessage: String?
    var transferCompleted: UInt64 = 0
    var transferTotal: UInt64?

    var showingNewFolderPrompt = false
    var showingRenamePrompt = false
    var showingDeleteConfirmation = false
    var showingOverwriteConfirmation = false
    var promptSide: SFTPBrowserSide = .local
    var nameInput = ""

    @ObservationIgnored private let service: CitadelSFTPService
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var pendingTransfer: PendingSFTPTransfer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var localSelectionAnchorID: LocalFileItem.ID?
    @ObservationIgnored private var remoteSelectionAnchorID: SFTPItem.ID?

    init(profile: SessionProfile, service: CitadelSFTPService) {
        self.profile = profile
        let home = FileManager.default.homeDirectoryForCurrentUser
        localCurrentURL = home
        localPathInput = home.path
        self.service = service
        loadLocal(url: home, recordingHistory: false)
    }

    var visibleLocalItems: [LocalFileItem] {
        localItems.filter { item in
            (showsHiddenFiles || !item.isHidden)
                && (localSearchText.isEmpty || item.name.localizedCaseInsensitiveContains(localSearchText))
        }
    }

    var visibleRemoteItems: [SFTPItem] {
        remoteItems.filter { item in
            (showsHiddenFiles || !item.name.hasPrefix("."))
                && (remoteSearchText.isEmpty || item.name.localizedCaseInsensitiveContains(remoteSearchText))
        }
    }

    var selectedLocalItems: [LocalFileItem] {
        localItems.filter { selectedLocalItemIDs.contains($0.id) }
    }

    var selectedRemoteItems: [SFTPItem] {
        remoteItems.filter { selectedRemoteItemIDs.contains($0.id) }
    }

    var canUpload: Bool {
        isConnected && !isBusy && !selectedLocalItems.isEmpty
    }

    var canDownload: Bool {
        isConnected && !isBusy && !selectedRemoteItems.isEmpty
    }

    var canGoLocalUp: Bool {
        localCurrentURL.path != "/"
    }

    var canGoRemoteUp: Bool {
        isConnected && remoteCurrentPath != "/" && !remoteCurrentPath.isEmpty && !isBusy
    }

    var progressFraction: Double? {
        guard let transferTotal, transferTotal > 0 else { return nil }
        return min(Double(transferCompleted) / Double(transferTotal), 1)
    }

    var pendingTransferIsUpload: Bool {
        if case .upload = pendingTransfer { return true }
        return false
    }

    func start() {
        guard !started else { return }
        started = true
        connect()
    }

    func retry() {
        guard !isBusy else { return }
        connect()
    }

    func close() {
        operationTask?.cancel()
        operationTask = nil
        operationID = nil
        let service = service
        Task { await service.disconnect() }
    }

    func cancelOperation() {
        guard isBusy else { return }
        operationTask?.cancel()
        statusMessage = String(localized: "Cancelling…")
    }

    func refreshLocal() {
        loadLocal(url: localCurrentURL, recordingHistory: false)
    }

    func goToLocalPath() {
        let input = localPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let expanded = (input as NSString).expandingTildeInPath
        loadLocal(url: URL(fileURLWithPath: expanded, isDirectory: true), recordingHistory: true)
    }

    func goLocalHome() {
        loadLocal(url: FileManager.default.homeDirectoryForCurrentUser, recordingHistory: true)
    }

    func goLocalUp() {
        guard canGoLocalUp else { return }
        loadLocal(url: localCurrentURL.deletingLastPathComponent(), recordingHistory: true)
    }

    func goLocalBack() {
        guard let destination = localBackHistory.last else { return }
        let previous = localCurrentURL
        guard loadLocal(url: destination, recordingHistory: false) else { return }
        localBackHistory.removeLast()
        localForwardHistory.append(previous)
    }

    func goLocalForward() {
        guard let destination = localForwardHistory.last else { return }
        let previous = localCurrentURL
        guard loadLocal(url: destination, recordingHistory: false) else { return }
        localForwardHistory.removeLast()
        localBackHistory.append(previous)
    }

    func openLocal(_ item: LocalFileItem) {
        if item.isDirectory {
            loadLocal(url: item.url, recordingHistory: true)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func selectLocal(_ item: LocalFileItem, modifiers: NSEvent.ModifierFlags) {
        selectedLocalItemIDs = updatedSelection(
            current: selectedLocalItemIDs,
            itemID: item.id,
            visibleIDs: visibleLocalItems.map(\.id),
            anchorID: &localSelectionAnchorID,
            modifiers: modifiers
        )
    }

    func revealSelectedLocalItems() {
        let urls = selectedLocalItems.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func refreshRemote() {
        guard isConnected else {
            retry()
            return
        }
        loadRemote(path: remoteCurrentPath, history: .none)
    }

    func goToRemotePath() {
        let path = remotePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        loadRemote(path: path, history: .normal)
    }

    func goRemoteUp() {
        guard canGoRemoteUp else { return }
        loadRemote(path: SFTPPath.parent(of: remoteCurrentPath), history: .normal)
    }

    func goRemoteBack() {
        guard let destination = remoteBackHistory.last else { return }
        loadRemote(path: destination, history: .back)
    }

    func goRemoteForward() {
        guard let destination = remoteForwardHistory.last else { return }
        loadRemote(path: destination, history: .forward)
    }

    func openRemote(_ item: SFTPItem) {
        if item.isDirectory {
            loadRemote(path: item.path, history: .normal)
        } else {
            selectedRemoteItemIDs = [item.id]
            downloadSelected()
        }
    }

    func selectRemote(_ item: SFTPItem, modifiers: NSEvent.ModifierFlags) {
        selectedRemoteItemIDs = updatedSelection(
            current: selectedRemoteItemIDs,
            itemID: item.id,
            visibleIDs: visibleRemoteItems.map(\.id),
            anchorID: &remoteSelectionAnchorID,
            modifiers: modifiers
        )
    }

    func requestNewFolder(on side: SFTPBrowserSide) {
        guard !isBusy else { return }
        promptSide = side
        nameInput = ""
        showingNewFolderPrompt = true
    }

    func createFolder() {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SFTPPath.isValidName(name) else {
            errorMessage = String(localized: "Enter a valid name without slashes.")
            return
        }
        switch promptSide {
        case .local:
            guard !localItems.contains(where: { $0.name == name }) else {
                errorMessage = String(localized: "An item with this name already exists.")
                return
            }
            do {
                try FileManager.default.createDirectory(
                    at: localCurrentURL.appendingPathComponent(name, isDirectory: true),
                    withIntermediateDirectories: false
                )
                refreshLocal()
                statusMessage = String(format: String(localized: "Created folder %@"), name)
                errorMessage = nil
            } catch {
                errorMessage = String(localized: "Could not create the local folder.")
            }
        case .remote:
            guard !remoteItems.contains(where: { $0.name == name }) else {
                errorMessage = String(localized: "An item with this name already exists.")
                return
            }
            let path = SFTPPath.joining(remoteCurrentPath, name)
            perform(
                status: String(format: String(localized: "Creating %@…"), name),
                failure: String(localized: "Could not create the remote folder.")
            ) { [self] in
                try await service.createDirectory(at: path)
                try await updateRemoteDirectory(path: remoteCurrentPath)
                return String(format: String(localized: "Created folder %@"), name)
            }
        }
    }

    func requestRename(on side: SFTPBrowserSide) {
        guard !isBusy else { return }
        promptSide = side
        switch side {
        case .local:
            guard selectedLocalItems.count == 1, let item = selectedLocalItems.first else { return }
            nameInput = item.name
        case .remote:
            guard selectedRemoteItems.count == 1, let item = selectedRemoteItems.first else { return }
            nameInput = item.name
        }
        showingRenamePrompt = true
    }

    func renameSelectedItem() {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SFTPPath.isValidName(name) else {
            errorMessage = String(localized: "Enter a valid name without slashes.")
            return
        }
        switch promptSide {
        case .local:
            guard let item = selectedLocalItems.first, name != item.name else { return }
            guard !localItems.contains(where: { $0.id != item.id && $0.name == name }) else {
                errorMessage = String(localized: "An item with this name already exists.")
                return
            }
            do {
                try FileManager.default.moveItem(
                    at: item.url,
                    to: localCurrentURL.appendingPathComponent(name, isDirectory: item.isDirectory)
                )
                refreshLocal()
                statusMessage = String(format: String(localized: "Renamed %@"), item.name)
                errorMessage = nil
            } catch {
                errorMessage = String(localized: "Could not rename the local item.")
            }
        case .remote:
            guard let item = selectedRemoteItems.first, name != item.name else { return }
            guard !remoteItems.contains(where: { $0.id != item.id && $0.name == name }) else {
                errorMessage = String(localized: "An item with this name already exists.")
                return
            }
            let destination = SFTPPath.joining(remoteCurrentPath, name)
            perform(
                status: String(format: String(localized: "Renaming %@…"), item.name),
                failure: String(localized: "Could not rename the remote item.")
            ) { [self] in
                try await service.renameItem(at: item.path, to: destination)
                try await updateRemoteDirectory(path: remoteCurrentPath)
                return String(format: String(localized: "Renamed %@"), item.name)
            }
        }
    }

    func requestDelete(on side: SFTPBrowserSide) {
        guard !isBusy else { return }
        let hasSelection = side == .local ? !selectedLocalItems.isEmpty : !selectedRemoteItems.isEmpty
        guard hasSelection else { return }
        promptSide = side
        showingDeleteConfirmation = true
    }

    func deleteSelectedItems() {
        switch promptSide {
        case .local:
            let items = selectedLocalItems
            do {
                for item in items {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                }
                refreshLocal()
                statusMessage = String(localized: "Moved selected items to the Trash")
                errorMessage = nil
            } catch {
                refreshLocal()
                errorMessage = String(localized: "Could not move all selected items to the Trash.")
            }
        case .remote:
            let items = selectedRemoteItems
            perform(
                status: String(localized: "Deleting selected remote items…"),
                failure: String(localized: "Could not delete all selected remote items. Folders must be empty before deletion.")
            ) { [self] in
                for item in items {
                    try await service.removeItem(at: item.path, isDirectory: item.isDirectory)
                }
                try await updateRemoteDirectory(path: remoteCurrentPath)
                return String(localized: "Deleted selected remote items")
            }
        }
    }

    func uploadSelected() {
        requestUpload(selectedLocalItems.map(\.url))
    }

    func requestUpload(_ urls: [URL]) {
        guard !urls.isEmpty, isConnected, !isBusy else { return }
        let remoteNames = Set(remoteItems.map(\.name))
        if urls.contains(where: { remoteNames.contains($0.lastPathComponent) }) {
            pendingTransfer = .upload(urls)
            showingOverwriteConfirmation = true
        } else {
            upload(urls)
        }
    }

    func downloadSelected() {
        let items = selectedRemoteItems
        guard !items.isEmpty, isConnected, !isBusy else { return }
        let localNames = Set(localItems.map(\.name))
        if items.contains(where: { localNames.contains($0.name) }) {
            pendingTransfer = .download(items)
            showingOverwriteConfirmation = true
        } else {
            download(items)
        }
    }

    func cancelPendingTransfer() {
        pendingTransfer = nil
    }

    func confirmPendingTransfer() {
        let transfer = pendingTransfer
        pendingTransfer = nil
        switch transfer {
        case .upload(let urls): upload(urls)
        case .download(let items): download(items)
        case nil: break
        }
    }

    func copySelectedPaths(on side: SFTPBrowserSide) {
        let paths: [String]
        switch side {
        case .local: paths = selectedLocalItems.map { $0.url.path }
        case .remote: paths = selectedRemoteItems.map(\.path)
        }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        statusMessage = String(localized: "Copied selected paths")
    }

    private func connect() {
        isBusy = true
        errorMessage = nil
        statusMessage = String(localized: "Connecting to SFTP…")
        let id = UUID()
        operationID = id
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let home = try await service.connect()
                guard operationID == id else { return }
                isConnected = true
                try await updateRemoteDirectory(path: home)
                statusMessage = itemCountMessage(visibleRemoteItems.count)
            } catch is CancellationError {
                statusMessage = String(localized: "Operation cancelled")
            } catch {
                guard operationID == id else { return }
                isConnected = false
                errorMessage = errorMessage(for: error, fallback: String(localized: "Could not connect to SFTP."))
                statusMessage = ""
            }
            guard operationID == id else { return }
            isBusy = false
            operationTask = nil
        }
    }

    private enum RemoteHistoryAction {
        case none
        case normal
        case back
        case forward
    }

    private func loadRemote(path: String, history: RemoteHistoryAction) {
        let previous = remoteCurrentPath
        perform(
            status: String(localized: "Loading…"),
            failure: String(localized: "Could not load this remote folder.")
        ) { [self] in
            try await updateRemoteDirectory(path: path)
            guard previous != remoteCurrentPath else { return itemCountMessage(visibleRemoteItems.count) }
            switch history {
            case .none:
                break
            case .normal:
                if !previous.isEmpty { remoteBackHistory.append(previous) }
                remoteForwardHistory.removeAll()
            case .back:
                if remoteBackHistory.last == remoteCurrentPath { remoteBackHistory.removeLast() }
                if !previous.isEmpty { remoteForwardHistory.append(previous) }
            case .forward:
                if remoteForwardHistory.last == remoteCurrentPath { remoteForwardHistory.removeLast() }
                if !previous.isEmpty { remoteBackHistory.append(previous) }
            }
            return itemCountMessage(visibleRemoteItems.count)
        }
    }

    @discardableResult
    private func loadLocal(url: URL, recordingHistory: Bool) -> Bool {
        let destination = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = String(localized: "Could not load this local folder.")
            localPathInput = localCurrentURL.path
            return false
        }
        do {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            let loaded = urls.map { child -> LocalFileItem in
                let values = try? child.resourceValues(forKeys: keys)
                return LocalFileItem(
                    url: child,
                    name: child.lastPathComponent,
                    isDirectory: values?.isDirectory == true,
                    isSymbolicLink: values?.isSymbolicLink == true,
                    isHidden: values?.isHidden == true || child.lastPathComponent.hasPrefix("."),
                    size: values?.fileSize.map(UInt64.init),
                    modificationDate: values?.contentModificationDate
                )
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let previous = localCurrentURL
            localCurrentURL = destination
            localPathInput = destination.path
            localItems = loaded
            selectedLocalItemIDs.removeAll()
            if recordingHistory, previous != destination {
                localBackHistory.append(previous)
                localForwardHistory.removeAll()
            }
            errorMessage = nil
            statusMessage = itemCountMessage(loaded.filter { showsHiddenFiles || !$0.isHidden }.count)
            return true
        } catch {
            errorMessage = String(localized: "Could not load this local folder.")
            localPathInput = localCurrentURL.path
            return false
        }
    }

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        resetTransferProgress()
        perform(
            status: String(localized: "Uploading selected items…"),
            failure: String(localized: "Could not upload all selected items.")
        ) { [self] in
            for url in urls {
                statusMessage = String(format: String(localized: "Uploading %@…"), url.lastPathComponent)
                try await service.uploadItem(
                    localURL: url,
                    remotePath: SFTPPath.joining(remoteCurrentPath, url.lastPathComponent),
                    progress: progressHandler()
                )
            }
            try await updateRemoteDirectory(path: remoteCurrentPath)
            return String(localized: "Upload complete")
        }
    }

    private func download(_ items: [SFTPItem]) {
        guard !items.isEmpty else { return }
        resetTransferProgress()
        let destination = localCurrentURL
        perform(
            status: String(localized: "Downloading selected items…"),
            failure: String(localized: "Could not download all selected items.")
        ) { [self] in
            for item in items {
                statusMessage = String(format: String(localized: "Downloading %@…"), item.name)
                try await service.downloadItem(
                    remoteItem: item,
                    localURL: destination.appendingPathComponent(item.name, isDirectory: item.isDirectory),
                    progress: progressHandler()
                )
            }
            refreshLocal()
            return String(localized: "Download complete")
        }
    }

    private func perform(
        status: String,
        failure: String,
        operation: @escaping @MainActor () async throws -> String?
    ) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = status
        let id = UUID()
        operationID = id
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let success = try await operation(), operationID == id {
                    statusMessage = success
                }
            } catch is CancellationError {
                if operationID == id { statusMessage = String(localized: "Operation cancelled") }
            } catch {
                if operationID == id { errorMessage = errorMessage(for: error, fallback: failure) }
            }
            guard operationID == id else { return }
            isBusy = false
            operationTask = nil
        }
    }

    private func updateRemoteDirectory(path: String) async throws {
        let directory = try await service.listDirectory(at: path)
        remoteCurrentPath = directory.path
        remotePathInput = directory.path
        remoteItems = directory.items
        selectedRemoteItemIDs.removeAll()
    }

    private func progressHandler() -> SFTPTransferProgress {
        { [weak self] completed, total in
            Task { @MainActor in
                self?.transferCompleted = completed
                self?.transferTotal = total
            }
        }
    }

    private func resetTransferProgress() {
        transferCompleted = 0
        transferTotal = nil
    }

    private func itemCountMessage(_ count: Int) -> String {
        if count == 1 { return String(localized: "1 item") }
        return String(format: String(localized: "%lld items"), count)
    }

    private func updatedSelection<ID: Hashable>(
        current: Set<ID>,
        itemID: ID,
        visibleIDs: [ID],
        anchorID: inout ID?,
        modifiers: NSEvent.ModifierFlags
    ) -> Set<ID> {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift),
           let anchorID,
           let anchorIndex = visibleIDs.firstIndex(of: anchorID),
           let itemIndex = visibleIDs.firstIndex(of: itemID) {
            let range = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
            let rangeSelection = Set(range.map { visibleIDs[$0] })
            return flags.contains(.command) ? current.union(rangeSelection) : rangeSelection
        }
        anchorID = itemID
        if flags.contains(.command) {
            var selection = current
            if selection.contains(itemID) {
                selection.remove(itemID)
            } else {
                selection.insert(itemID)
            }
            return selection
        }
        return [itemID]
    }

    private func errorMessage(for error: Error, fallback: String) -> String {
        if let serviceError = error as? SFTPServiceError {
            switch serviceError {
            case .notConnected:
                isConnected = false
            case .destinationTypeMismatch:
                return String(localized: "The destination contains an item of a different type.")
            case .invalidName, .localFileUnavailable:
                break
            }
        }
        if let sshError = error as? SSHError {
            if case .connectionClosed = sshError { isConnected = false }
            return sshError.userMessage
        }
        AppLog.ssh.error("SFTP operation failed")
        return fallback
    }
}

@MainActor
@Observable
final class SFTPHostKeyPromptCoordinator {
    var prompt: HostKeyPromptState?
    @ObservationIgnored private var continuation: CheckedContinuation<HostKeyDecision, Never>?

    func request(_ check: HostKeyCheck) async -> HostKeyDecision {
        let request = HostKeyPromptState(check: check)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancel); return }
                if let existing = self.continuation {
                    self.continuation = nil
                    existing.resume(returning: .cancel)
                }
                self.continuation = continuation
                prompt = request
            }
        } onCancel: {
            Task { @MainActor in
                if self.prompt?.id == request.id { self.cancel() }
            }
        }
    }

    func resolve(_ decision: HostKeyDecision) {
        prompt = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: decision)
    }

    func cancel() {
        resolve(.cancel)
    }
}

final class SFTPHostKeyBridge: @unchecked Sendable {
    @MainActor weak var coordinator: SFTPHostKeyPromptCoordinator?

    @MainActor
    init(coordinator: SFTPHostKeyPromptCoordinator) {
        self.coordinator = coordinator
    }

    func prompt(_ check: HostKeyCheck) async -> HostKeyDecision {
        await coordinator?.request(check) ?? .cancel
    }
}

@MainActor
final class SFTPWindowController: NSWindowController, NSWindowDelegate {
    private static let preferredContentSize = NSSize(width: 1180, height: 720)

    let id: UUID
    private let browser: SFTPBrowserModel
    private let promptCoordinator: SFTPHostKeyPromptCoordinator
    private let onClose: @MainActor (UUID) -> Void

    init(
        id: UUID,
        browser: SFTPBrowserModel,
        promptCoordinator: SFTPHostKeyPromptCoordinator,
        onClose: @escaping @MainActor (UUID) -> Void
    ) {
        self.id = id
        self.browser = browser
        self.promptCoordinator = promptCoordinator
        self.onClose = onClose

        let rootView = SFTPBrowserView(browser: browser, promptCoordinator: promptCoordinator)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.preferredContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: String(localized: "SFTP — %@"), browser.profile.displayName)
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 900, height: 560)
        window.setContentSize(Self.preferredContentSize)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        let targetScreen = presentationScreen
        window.contentView?.layoutSubtreeIfNeeded()
        size(window, toFit: targetScreen)
        center(window, on: targetScreen)
        window.makeKeyAndOrderFront(sender)
        NSApp.activate()
    }

    private var presentationScreen: NSScreen? {
        if let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen {
            return screen
        }
        let pointerLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointerLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func size(_ window: NSWindow, toFit screen: NSScreen?) {
        window.setContentSize(Self.preferredContentSize)
        guard let screen else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, screen.visibleFrame.width)
        frame.size.height = min(frame.height, screen.visibleFrame.height)
        window.setFrame(frame, display: false)
    }

    private func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            window.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let windowFrame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - windowFrame.width / 2,
            y: visibleFrame.midY - windowFrame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    func windowWillClose(_ notification: Notification) {
        promptCoordinator.cancel()
        browser.close()
        onClose(id)
    }
}

struct SFTPBrowserView: View {
    @Bindable var browser: SFTPBrowserModel
    @Bindable var promptCoordinator: SFTPHostKeyPromptCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                localPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                transferControls
                Divider()
                remotePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { browser.start() }
        .sheet(item: hostKeyPromptBinding) { prompt in
            HostKeyDecisionView(check: prompt.check) { decision in
                promptCoordinator.resolve(decision)
            }
        }
        .alert(newFolderPromptTitle, isPresented: $browser.showingNewFolderPrompt) {
            TextField("Name", text: $browser.nameInput)
            Button("Cancel", role: .cancel) {}
            Button("Create") { browser.createFolder() }
        }
        .alert(renamePromptTitle, isPresented: $browser.showingRenamePrompt) {
            TextField("Name", text: $browser.nameInput)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { browser.renameSelectedItem() }
        }
        .alert(deletePromptTitle, isPresented: $browser.showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(deleteActionTitle, role: .destructive) { browser.deleteSelectedItems() }
        } message: {
            Text(deletePromptMessage)
        }
        .alert(overwritePromptTitle, isPresented: $browser.showingOverwriteConfirmation) {
            Button("Cancel", role: .cancel) { browser.cancelPendingTransfer() }
            Button("Replace") { browser.confirmPendingTransfer() }
        } message: {
            Text(overwritePromptMessage)
        }
    }

    private var localPane: some View {
        FilePaneContainer(title: String(localized: "Local"), systemImage: "laptopcomputer") {
            pathBar(
                path: $browser.localPathInput,
                placeholder: String(localized: "Local path"),
                canBack: !browser.localBackHistory.isEmpty,
                canForward: !browser.localForwardHistory.isEmpty,
                canUp: browser.canGoLocalUp,
                back: browser.goLocalBack,
                forward: browser.goLocalForward,
                up: browser.goLocalUp,
                go: browser.goToLocalPath,
                refresh: browser.refreshLocal
            )
            localActionBar
            LocalListHeader()
            List(selection: $browser.selectedLocalItemIDs) {
                ForEach(browser.visibleLocalItems) { item in
                    LocalItemRow(item: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            browser.selectLocal(item, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded { browser.openLocal(item) }
                        )
                        .draggable(item.url)
                        .tag(item.id)
                        .contextMenu { localItemMenu(item) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onDeleteCommand { browser.requestDelete(on: .local) }
            .overlay {
                if browser.visibleLocalItems.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "folder", description: Text("This folder is empty."))
                }
            }
        }
    }

    private var remotePane: some View {
        FilePaneContainer(title: String(localized: "Remote"), systemImage: "server.rack") {
            pathBar(
                path: $browser.remotePathInput,
                placeholder: String(localized: "Remote path"),
                canBack: !browser.remoteBackHistory.isEmpty && !browser.isBusy,
                canForward: !browser.remoteForwardHistory.isEmpty && !browser.isBusy,
                canUp: browser.canGoRemoteUp,
                back: browser.goRemoteBack,
                forward: browser.goRemoteForward,
                up: browser.goRemoteUp,
                go: browser.goToRemotePath,
                refresh: browser.refreshRemote
            )
            .disabled(!browser.isConnected || browser.isBusy)
            remoteActionBar
            RemoteListHeader()
            if browser.isConnected {
                List(selection: $browser.selectedRemoteItemIDs) {
                    ForEach(browser.visibleRemoteItems) { item in
                        RemoteItemRow(item: item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                browser.selectRemote(item, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                            }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { browser.openRemote(item) }
                            )
                            .tag(item.id)
                            .contextMenu { remoteItemMenu(item) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand { browser.requestDelete(on: .remote) }
                .overlay {
                    if browser.visibleRemoteItems.isEmpty && !browser.isBusy {
                        ContentUnavailableView("No Files", systemImage: "folder", description: Text("This folder is empty."))
                    }
                }
            } else {
                remoteUnavailableView
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard browser.isConnected, !browser.isBusy else { return false }
            browser.requestUpload(urls)
            return !urls.isEmpty
        }
    }

    private var localActionBar: some View {
        HStack(spacing: 7) {
            Button("Home", systemImage: "house") { browser.goLocalHome() }
                .labelStyle(.iconOnly)
                .help("Home")
            Button("New Folder", systemImage: "folder.badge.plus") { browser.requestNewFolder(on: .local) }
                .labelStyle(.iconOnly)
                .help("New Folder")
                .disabled(browser.isBusy)
            Button("Rename", systemImage: "pencil") { browser.requestRename(on: .local) }
                .labelStyle(.iconOnly)
                .help("Rename")
                .disabled(browser.selectedLocalItems.count != 1 || browser.isBusy)
            Button("Move to Trash", systemImage: "trash", role: .destructive) { browser.requestDelete(on: .local) }
                .labelStyle(.iconOnly)
                .help("Move to Trash")
                .disabled(browser.selectedLocalItems.isEmpty || browser.isBusy)
            Menu {
                Button("Open") {
                    if let item = browser.selectedLocalItems.first { browser.openLocal(item) }
                }
                .disabled(browser.selectedLocalItems.count != 1)
                Button("Reveal in Finder") { browser.revealSelectedLocalItems() }
                    .disabled(browser.selectedLocalItems.isEmpty)
                Button("Copy Path") { browser.copySelectedPaths(on: .local) }
                    .disabled(browser.selectedLocalItems.isEmpty)
                Divider()
                Button(browser.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files") {
                    browser.showsHiddenFiles.toggle()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            Spacer()
            TextField("Search", text: $browser.localSearchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var remoteActionBar: some View {
        HStack(spacing: 7) {
            Button("New Folder", systemImage: "folder.badge.plus") { browser.requestNewFolder(on: .remote) }
                .labelStyle(.iconOnly)
                .help("New Folder")
            Button("Rename", systemImage: "pencil") { browser.requestRename(on: .remote) }
                .labelStyle(.iconOnly)
                .help("Rename")
                .disabled(browser.selectedRemoteItems.count != 1)
            Button("Delete", systemImage: "trash", role: .destructive) { browser.requestDelete(on: .remote) }
                .labelStyle(.iconOnly)
                .help("Delete")
                .disabled(browser.selectedRemoteItems.isEmpty)
            Menu {
                Button("Open") {
                    if let item = browser.selectedRemoteItems.first { browser.openRemote(item) }
                }
                .disabled(browser.selectedRemoteItems.count != 1)
                Button("Copy Path") { browser.copySelectedPaths(on: .remote) }
                    .disabled(browser.selectedRemoteItems.isEmpty)
                Divider()
                Button(browser.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files") {
                    browser.showsHiddenFiles.toggle()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            Spacer()
            TextField("Search", text: $browser.remoteSearchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .disabled(!browser.isConnected || browser.isBusy)
    }

    private func pathBar(
        path: Binding<String>,
        placeholder: String,
        canBack: Bool,
        canForward: Bool,
        canUp: Bool,
        back: @escaping () -> Void,
        forward: @escaping () -> Void,
        up: @escaping () -> Void,
        go: @escaping () -> Void,
        refresh: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button("Back", systemImage: "chevron.left", action: back)
                .labelStyle(.iconOnly)
                .help("Back")
                .disabled(!canBack)
            Button("Forward", systemImage: "chevron.right", action: forward)
                .labelStyle(.iconOnly)
                .help("Forward")
                .disabled(!canForward)
            Button("Parent Directory", systemImage: "chevron.up", action: up)
                .labelStyle(.iconOnly)
                .help("Parent Directory")
                .disabled(!canUp)
            TextField(placeholder, text: path)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
            Button("Go", action: go)
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .help("Refresh")
        }
        .padding(10)
    }

    private var transferControls: some View {
        VStack(spacing: 14) {
            Spacer()
            Button {
                browser.uploadSelected()
            } label: {
                Image(systemName: "arrow.right")
                    .font(.title3.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .help("Upload Selected")
            .disabled(!browser.canUpload)

            Button {
                browser.downloadSelected()
            } label: {
                Image(systemName: "arrow.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .help("Download Selected")
            .disabled(!browser.canDownload)

            if browser.isBusy {
                Button("Cancel Transfer", systemImage: "xmark.circle") { browser.cancelOperation() }
                    .labelStyle(.iconOnly)
                    .help("Cancel Transfer")
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 58)
        .background(.quaternary.opacity(0.18))
    }

    @ViewBuilder
    private func localItemMenu(_ item: LocalFileItem) -> some View {
        Button("Open") {
            browser.selectedLocalItemIDs = [item.id]
            browser.openLocal(item)
        }
        Button("Upload") {
            browser.selectedLocalItemIDs = [item.id]
            browser.uploadSelected()
        }
        .disabled(!browser.isConnected || browser.isBusy)
        Divider()
        Button("Reveal in Finder") {
            browser.selectedLocalItemIDs = [item.id]
            browser.revealSelectedLocalItems()
        }
        Button("Copy Path") {
            browser.selectedLocalItemIDs = [item.id]
            browser.copySelectedPaths(on: .local)
        }
        Button("Rename") {
            browser.selectedLocalItemIDs = [item.id]
            browser.requestRename(on: .local)
        }
        Button("Move to Trash", role: .destructive) {
            browser.selectedLocalItemIDs = [item.id]
            browser.requestDelete(on: .local)
        }
    }

    @ViewBuilder
    private func remoteItemMenu(_ item: SFTPItem) -> some View {
        if item.isDirectory {
            Button("Open") { browser.openRemote(item) }
        }
        Button("Download") {
            browser.selectedRemoteItemIDs = [item.id]
            browser.downloadSelected()
        }
        Divider()
        Button("Copy Path") {
            browser.selectedRemoteItemIDs = [item.id]
            browser.copySelectedPaths(on: .remote)
        }
        Button("Rename") {
            browser.selectedRemoteItemIDs = [item.id]
            browser.requestRename(on: .remote)
        }
        Button("Delete", role: .destructive) {
            browser.selectedRemoteItemIDs = [item.id]
            browser.requestDelete(on: .remote)
        }
    }

    private var remoteUnavailableView: some View {
        ContentUnavailableView {
            Label("SFTP", systemImage: "externaldrive.connected.to.line.below")
        } description: {
            if browser.isBusy {
                Text("Connecting to SFTP…")
            } else {
                Text(browser.errorMessage ?? String(localized: "Could not connect to SFTP."))
            }
        } actions: {
            if browser.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("Retry") { browser.retry() }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if browser.isBusy {
                if let fraction = browser.progressFraction {
                    ProgressView(value: fraction).frame(width: 130)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(browser.errorMessage ?? browser.statusMessage)
                .foregroundStyle(browser.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(1)
            Spacer()
            if !browser.remoteCurrentPath.isEmpty {
                Text(verbatim: "\(browser.profile.username)@\(browser.profile.host):\(browser.remoteCurrentPath)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var hostKeyPromptBinding: Binding<HostKeyPromptState?> {
        Binding(
            get: { promptCoordinator.prompt },
            set: { if $0 == nil, promptCoordinator.prompt != nil { promptCoordinator.cancel() } }
        )
    }

    private var newFolderPromptTitle: String {
        browser.promptSide == .local
            ? String(localized: "New Local Folder")
            : String(localized: "New Remote Folder")
    }

    private var renamePromptTitle: String {
        let name = browser.promptSide == .local
            ? browser.selectedLocalItems.first?.name
            : browser.selectedRemoteItems.first?.name
        guard let name else { return String(localized: "Rename") }
        return String(format: String(localized: "Rename “%@”"), name)
    }

    private var deletePromptTitle: String {
        if browser.promptSide == .local {
            if browser.selectedLocalItems.count == 1, let name = browser.selectedLocalItems.first?.name {
                return String(format: String(localized: "Move “%@” to Trash?"), name)
            }
            return String(localized: "Move selected items to Trash?")
        }
        if browser.selectedRemoteItems.count == 1, let name = browser.selectedRemoteItems.first?.name {
            return String(format: String(localized: "Delete “%@”?"), name)
        }
        return String(localized: "Delete selected remote items?")
    }

    private var deleteActionTitle: LocalizedStringKey {
        browser.promptSide == .local ? "Move to Trash" : "Delete"
    }

    private var deletePromptMessage: LocalizedStringKey {
        browser.promptSide == .local
            ? "The selected local items will be moved to the Trash."
            : "This permanently deletes the selected remote items. This action cannot be undone."
    }

    private var overwritePromptTitle: LocalizedStringKey {
        if browser.pendingTransferIsUpload {
            "Replace existing remote items?"
        } else {
            "Replace existing local items?"
        }
    }

    private var overwritePromptMessage: LocalizedStringKey {
        if browser.pendingTransferIsUpload {
            "One or more items already exist on the server. Files will be replaced and folders will be merged."
        } else {
            "One or more items already exist locally. Files will be replaced and folders will be merged."
        }
    }
}

private struct FilePaneContainer<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            content
        }
    }
}

private struct LocalListHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: 82, alignment: .trailing)
            Text("Modified").frame(width: 128, alignment: .leading)
        }
        .fileListHeaderStyle()
    }
}

private struct RemoteListHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: 70, alignment: .trailing)
            Text("Modified").frame(width: 118, alignment: .leading)
            Text("Permissions").frame(width: 62, alignment: .leading)
        }
        .fileListHeaderStyle()
    }
}

private struct FileListHeaderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.35))
    }
}

private extension View {
    func fileListHeaderStyle() -> some View {
        modifier(FileListHeaderModifier())
    }
}

private struct LocalItemRow: View {
    let item: LocalFileItem

    var body: some View {
        HStack(spacing: 12) {
            Label(item.name, systemImage: iconName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(sizeText).frame(width: 82, alignment: .trailing)
            Text(modifiedText).frame(width: 128, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private var iconName: String {
        if item.isSymbolicLink { return "link" }
        return item.isDirectory ? "folder.fill" : "doc"
    }

    private var sizeText: String {
        guard !item.isDirectory, let size = item.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }

    private var modifiedText: String {
        item.modificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }
}

private struct RemoteItemRow: View {
    let item: SFTPItem

    var body: some View {
        HStack(spacing: 12) {
            Label(item.name, systemImage: iconName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(sizeText).frame(width: 70, alignment: .trailing)
            Text(modifiedText).frame(width: 118, alignment: .leading)
            Text(permissionsText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 62, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch item.kind {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .file: "doc"
        }
    }

    private var sizeText: String {
        guard !item.isDirectory, let size = item.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }

    private var modifiedText: String {
        item.modificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    private var permissionsText: String {
        guard let permissions = item.permissions else { return "—" }
        return String(format: "%04o", permissions & 0o7777)
    }
}
