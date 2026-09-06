import AppKit
import Observation
import SwiftUI
import TermeowKit

@MainActor
@Observable
final class SFTPBrowserModel: Identifiable {
    let id = UUID()
    let profile: SessionProfile
    var currentPath = ""
    var pathInput = ""
    var items: [SFTPItem] = []
    var selectedItemID: SFTPItem.ID?
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
    var nameInput = ""
    var pendingDeleteItem: SFTPItem?
    var pendingUploadURLs: [URL] = []

    @ObservationIgnored private let service: CitadelSFTPService
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(profile: SessionProfile, service: CitadelSFTPService) {
        self.profile = profile
        self.service = service
    }

    var selectedItem: SFTPItem? {
        items.first { $0.id == selectedItemID }
    }

    var canGoUp: Bool {
        isConnected && !currentPath.isEmpty && currentPath != "/" && !isBusy
    }

    var progressFraction: Double? {
        guard let transferTotal, transferTotal > 0 else { return nil }
        return min(Double(transferCompleted) / Double(transferTotal), 1)
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
        let service = service
        Task { await service.disconnect() }
    }

    func refresh() {
        guard isConnected else {
            retry()
            return
        }
        load(path: currentPath)
    }

    func goToPath() {
        let path = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        load(path: path)
    }

    func goUp() {
        guard canGoUp else { return }
        load(path: SFTPPath.parent(of: currentPath))
    }

    func open(_ item: SFTPItem) {
        guard item.isDirectory else { return }
        load(path: item.path)
    }

    func requestNewFolder() {
        guard !isBusy else { return }
        nameInput = ""
        showingNewFolderPrompt = true
    }

    func createFolder() {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SFTPPath.isValidName(name) else {
            errorMessage = String(localized: "Enter a valid name without slashes.")
            return
        }
        guard !items.contains(where: { $0.name == name }) else {
            errorMessage = String(localized: "An item with this name already exists.")
            return
        }
        let path = SFTPPath.joining(currentPath, name)
        perform(
            status: String(format: String(localized: "Creating %@…"), name),
            failure: String(localized: "Could not create the folder.")
        ) { [self] in
            try await service.createDirectory(at: path)
            try await updateDirectory(path: currentPath)
            return String(format: String(localized: "Created folder %@"), name)
        }
    }

    func requestRename() {
        guard let item = selectedItem, !isBusy else { return }
        nameInput = item.name
        showingRenamePrompt = true
    }

    func renameSelectedItem() {
        guard let item = selectedItem else { return }
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SFTPPath.isValidName(name) else {
            errorMessage = String(localized: "Enter a valid name without slashes.")
            return
        }
        guard name != item.name else { return }
        guard !items.contains(where: { $0.id != item.id && $0.name == name }) else {
            errorMessage = String(localized: "An item with this name already exists.")
            return
        }
        let destination = SFTPPath.joining(currentPath, name)
        perform(
            status: String(format: String(localized: "Renaming %@…"), item.name),
            failure: String(localized: "Could not rename the item.")
        ) { [self] in
            try await service.renameItem(at: item.path, to: destination)
            try await updateDirectory(path: currentPath)
            return String(format: String(localized: "Renamed %@"), item.name)
        }
    }

    func requestDelete() {
        guard let item = selectedItem, !isBusy else { return }
        pendingDeleteItem = item
        showingDeleteConfirmation = true
    }

    func deletePendingItem() {
        guard let item = pendingDeleteItem else { return }
        pendingDeleteItem = nil
        perform(
            status: String(format: String(localized: "Deleting %@…"), item.name),
            failure: String(localized: "Could not delete the item. Folders must be empty before deletion.")
        ) { [self] in
            try await service.removeItem(at: item.path, isDirectory: item.isDirectory)
            try await updateDirectory(path: currentPath)
            return String(format: String(localized: "Deleted %@"), item.name)
        }
    }

    func requestUpload(_ urls: [URL]) {
        guard !urls.isEmpty, !isBusy else { return }
        let uploadNames = urls.map(\.lastPathComponent)
        let existingNames = Set(items.map(\.name))
        let hasConflicts = Set(uploadNames).count != uploadNames.count
            || uploadNames.contains { existingNames.contains($0) }
        if hasConflicts {
            pendingUploadURLs = urls
            showingOverwriteConfirmation = true
        } else {
            upload(urls)
        }
    }

    func confirmPendingUpload() {
        let urls = pendingUploadURLs
        pendingUploadURLs = []
        upload(urls)
    }

    func download(_ item: SFTPItem, to localURL: URL) {
        guard !item.isDirectory else { return }
        resetTransferProgress()
        perform(
            status: String(format: String(localized: "Downloading %@…"), item.name),
            failure: String(format: String(localized: "Could not download %@."), item.name)
        ) { [self] in
            try await service.download(
                remotePath: item.path,
                localURL: localURL,
                progress: progressHandler()
            )
            return String(format: String(localized: "Downloaded %@"), item.name)
        }
    }

    private func connect() {
        isBusy = true
        errorMessage = nil
        statusMessage = String(localized: "Connecting to SFTP…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let home = try await service.connect()
                isConnected = true
                try await updateDirectory(path: home)
                statusMessage = itemCountMessage
            } catch {
                guard !Task.isCancelled else { return }
                isConnected = false
                errorMessage = errorMessage(for: error, fallback: String(localized: "Could not connect to SFTP."))
                statusMessage = ""
            }
            isBusy = false
        }
    }

    private func load(path: String) {
        perform(
            status: String(localized: "Loading…"),
            failure: String(localized: "Could not load this folder.")
        ) { [self] in
            try await updateDirectory(path: path)
            return itemCountMessage
        }
    }

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        resetTransferProgress()
        perform(
            status: String(localized: "Uploading…"),
            failure: String(localized: "Could not upload the selected files.")
        ) { [self] in
            for url in urls {
                statusMessage = String(format: String(localized: "Uploading %@…"), url.lastPathComponent)
                try await service.upload(
                    localURL: url,
                    remotePath: SFTPPath.joining(currentPath, url.lastPathComponent),
                    progress: progressHandler()
                )
            }
            try await updateDirectory(path: currentPath)
            return String(localized: "Upload complete")
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
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let success = try await operation() {
                    statusMessage = success
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = errorMessage(for: error, fallback: failure)
            }
            isBusy = false
        }
    }

    private func updateDirectory(path: String) async throws {
        let directory = try await service.listDirectory(at: path)
        currentPath = directory.path
        pathInput = directory.path
        items = directory.items
        selectedItemID = nil
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

    private var itemCountMessage: String {
        if items.count == 1 { return String(localized: "1 item") }
        return String(format: String(localized: "%lld items"), items.count)
    }

    private func errorMessage(for error: Error, fallback: String) -> String {
        if let serviceError = error as? SFTPServiceError,
           case .notConnected = serviceError {
            isConnected = false
        }
        if let sshError = error as? SSHError {
            if case .connectionClosed = sshError {
                isConnected = false
            }
            return sshError.userMessage
        }
        AppLog.ssh.error("SFTP operation failed")
        return fallback
    }
}

struct SFTPBrowserView: View {
    @Bindable var browser: SFTPBrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 820, minHeight: 540)
        .navigationTitle(String(format: String(localized: "SFTP — %@"), browser.profile.displayName))
        .task { browser.start() }
        .onDisappear { browser.close() }
        .alert("New Folder", isPresented: $browser.showingNewFolderPrompt) {
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
            Button("Cancel", role: .cancel) { browser.pendingDeleteItem = nil }
            Button("Delete", role: .destructive) { browser.deletePendingItem() }
        } message: {
            Text("This permanently deletes the selected remote item. This action cannot be undone.")
        }
        .alert("Replace existing remote files?", isPresented: $browser.showingOverwriteConfirmation) {
            Button("Cancel", role: .cancel) { browser.pendingUploadURLs = [] }
            Button("Replace") { browser.confirmPendingUpload() }
        } message: {
            Text("One or more files already exist in this folder. Replacing them cannot be undone.")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button("Parent Directory", systemImage: "chevron.up") { browser.goUp() }
                    .labelStyle(.iconOnly)
                    .help("Parent Directory")
                    .disabled(!browser.canGoUp)
                TextField("Remote path", text: $browser.pathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.goToPath() }
                    .disabled(!browser.isConnected || browser.isBusy)
                Button("Go") { browser.goToPath() }
                    .disabled(!browser.isConnected || browser.isBusy)
                Button("Refresh", systemImage: "arrow.clockwise") { browser.refresh() }
                    .labelStyle(.iconOnly)
                    .help("Refresh")
                    .disabled(browser.isBusy)
            }
            HStack(spacing: 8) {
                Group {
                    Button("Upload", systemImage: "arrow.up.doc") { chooseUploadFiles() }
                    Button("Download", systemImage: "arrow.down.doc") { chooseDownloadDestination() }
                        .disabled(browser.selectedItem == nil || browser.selectedItem?.isDirectory == true)
                    Divider().frame(height: 18)
                    Button("New Folder", systemImage: "folder.badge.plus") { browser.requestNewFolder() }
                    Button("Rename", systemImage: "pencil") { browser.requestRename() }
                        .disabled(browser.selectedItem == nil)
                    Button("Delete", systemImage: "trash", role: .destructive) { browser.requestDelete() }
                        .disabled(browser.selectedItem == nil)
                }
                .disabled(!browser.isConnected || browser.isBusy)
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if browser.isConnected {
            VStack(spacing: 0) {
                SFTPListHeader()
                List(selection: $browser.selectedItemID) {
                    ForEach(browser.items) { item in
                        let selected = browser.selectedItemID == item.id
                        SFTPItemRow(item: item, selected: selected)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                selected ? Color.blue : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .onTapGesture { browser.selectedItemID = item.id }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    if item.isDirectory {
                                        browser.open(item)
                                    } else {
                                        browser.selectedItemID = item.id
                                        chooseDownloadDestination()
                                    }
                                }
                            )
                            .tag(item.id)
                            .contextMenu { itemMenu(item) }
                    }
                }
                .overlay {
                    if browser.items.isEmpty && !browser.isBusy {
                        ContentUnavailableView("No Files", systemImage: "folder", description: Text("This folder is empty."))
                    }
                }
            }
        } else {
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
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Retry") { browser.retry() }
                }
            }
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: SFTPItem) -> some View {
        if item.isDirectory {
            Button("Open") { browser.open(item) }
        } else {
            Button("Download") {
                browser.selectedItemID = item.id
                chooseDownloadDestination()
            }
        }
        Divider()
        Button("Rename") {
            browser.selectedItemID = item.id
            browser.requestRename()
        }
        Button("Delete", role: .destructive) {
            browser.selectedItemID = item.id
            browser.requestDelete()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if browser.isBusy {
                if let fraction = browser.progressFraction {
                    ProgressView(value: fraction)
                        .frame(width: 130)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(browser.errorMessage ?? browser.statusMessage)
                .foregroundStyle(browser.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(1)
            Spacer()
            if !browser.currentPath.isEmpty {
                Text(verbatim: browser.currentPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var renamePromptTitle: String {
        guard let item = browser.selectedItem else { return String(localized: "Rename") }
        return String(format: String(localized: "Rename “%@”"), item.name)
    }

    private var deletePromptTitle: String {
        guard let item = browser.pendingDeleteItem else { return String(localized: "Delete") }
        return String(format: String(localized: "Delete “%@”?"), item.name)
    }

    private func chooseUploadFiles() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Upload Files")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        browser.requestUpload(panel.urls)
    }

    private func chooseDownloadDestination() {
        guard let item = browser.selectedItem, !item.isDirectory else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Download File")
        panel.nameFieldStringValue = item.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        browser.download(item, to: url)
    }
}

private struct SFTPListHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(width: 90, alignment: .trailing)
            Text("Modified")
                .frame(width: 150, alignment: .leading)
            Text("Permissions")
                .frame(width: 80, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
    }
}

private struct SFTPItemRow: View {
    let item: SFTPItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Label(item.name, systemImage: iconName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(sizeText)
                .frame(width: 90, alignment: .trailing)
            Text(modifiedText)
                .frame(width: 150, alignment: .leading)
            Text(permissionsText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 80, alignment: .leading)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
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
