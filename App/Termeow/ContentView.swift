import SwiftUI
import TermeowKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: visibility) {
            SessionSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detailColumn
        }
        .toolbar(removing: .title)
        .sheet(item: $model.editor) { editor in
            SessionEditorView(state: editor)
        }
        .sheet(item: hostKeyPromptBinding) { prompt in
            HostKeyView(check: prompt.check)
        }
        .alert(item: $model.sessionPendingDeletion) { profile in
            Alert(
                title: Text(String(format: String(localized: "Delete “%@”?"), profile.displayName)),
                message: Text("This removes the saved session and closes its open tabs. This action cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    model.confirmDelete(profile)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $model.tabPendingClosure) { request in
            Alert(
                title: Text(String(format: String(localized: "Close “%@”?"), request.title)),
                message: Text("This tab has active SSH connections. Closing it will disconnect all sessions."),
                primaryButton: .destructive(Text("Close and Disconnect")) {
                    model.confirmCloseTab(request)
                },
                secondaryButton: .cancel {
                    model.cancelCloseTab()
                }
            )
        }
        .alert(item: $model.panePendingClosure) { request in
            Alert(
                title: Text(String(format: String(localized: "Close “%@” Pane?"), request.title)),
                message: Text("This pane has an active SSH connection. Closing it will disconnect the session."),
                primaryButton: .destructive(Text("Close and Disconnect")) {
                    model.confirmClosePane(request)
                },
                secondaryButton: .cancel {
                    model.cancelClosePane()
                }
            )
        }
    }

    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly }
        )
    }

    private var hostKeyPromptBinding: Binding<HostKeyPromptState?> {
        Binding(
            get: { model.hostKeyPrompt },
            set: { if $0 == nil, model.hostKeyPrompt != nil { model.resolveHostKey(.cancel) } }
        )
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            TabBarView()
            detailBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.statusBarVisible {
                StatusBarView()
            }
        }
        .navigationTitle(model.selectedTab?.controller.title ?? "Termeow")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
                .help("Settings…")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Open SFTP", systemImage: "externaldrive.connected.to.line.below") {
                    model.openSelectedSFTP()
                }
                .disabled(model.sftpContextProfile == nil)
                .help("Open SFTP")
            }
        }
    }

    @ViewBuilder
    private var detailBody: some View {
        if let tab = model.selectedTab {
            TerminalWorkspaceView(tabID: tab.id)
                .id(tab.id)
        } else {
            EmptyTerminalView()
        }
    }
}

struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let tab = model.selectedTab {
                Text(verbatim: "\(tab.controller.profile.host):\(tab.controller.profile.port)")
                Text(tab.controller.statusText)
                Text(verbatim: "\(tab.controller.cols)×\(tab.controller.rows)")
                if tab.paneCount > 1,
                   let paneIndex = tab.layout.paneIDs.firstIndex(of: tab.selectedPaneID) {
                    Text(
                        String(
                            format: String(localized: "Pane %lld of %lld"),
                            Int64(paneIndex + 1),
                            Int64(tab.paneCount)
                        )
                    )
                }
                if let error = tab.controller.lastError {
                    Text(error).foregroundStyle(.red)
                }
            } else {
                Text("Ready")
            }
            Spacer()
            if let message = model.statusMessage {
                Text(message)
            }
            SettingsLink {
                HStack(spacing: 6) {
                    Text(model.typography.statusLabel)
                    Text("·")
                    Text(LocalizedStringKey(model.colorSchemeID.title))
                }
            }
            .buttonStyle(.plain)
            .help("Settings…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

struct EmptyTerminalView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Terminal", systemImage: "terminal")
        } description: {
            Text("Double-click a session to connect.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
