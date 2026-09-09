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
        .sheet(item: $model.forwardingController) { controller in
            PortForwardingPanel(controller: controller)
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
        .alert("Close Tabs?", isPresented: Binding(
            get: { model.tabPendingClosure != nil },
            set: { if !$0 { model.cancelCloseTab() } }
        ), presenting: model.tabPendingClosure) { request in
            Button("Close and Disconnect", role: .destructive) { model.confirmCloseTab(request) }
            Button("Cancel", role: .cancel) { model.cancelCloseTab() }
        } message: { request in
            Text(String(format: String(localized: "Closing “%@” will disconnect its active SSH sessions."), request.title))
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
        GroupWorkspaceView()
    }
}

struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let tab = model.selectedTab {
                Text(verbatim: "\(tab.controller.profile.host):\(tab.controller.profile.port)")
                Text(tab.controller.statusText)
                if !tab.controller.portForwardStatuses.isEmpty {
                    Button("Tunnels: \(tab.controller.portForwardStatuses.filter { $0.state == .listening }.count)/\(tab.controller.portForwardStatuses.count)") {
                        model.forwardingController = tab.controller
                    }
                    .buttonStyle(.borderless)
                }
                Text(verbatim: "\(tab.controller.cols)×\(tab.controller.rows)")
                if model.tabGroups.groups.count > 1,
                   let paneIndex = model.tabGroups.layout.paneIDs.firstIndex(of: model.tabGroups.activeGroupID) {
                    Text(
                        String(
                            format: String(localized: "Group %lld of %lld"),
                            Int64(paneIndex + 1),
                            Int64(model.tabGroups.groups.count)
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

struct PortForwardingPanel: View {
    @Environment(\.dismiss) private var dismiss
    let controller: ConnectionController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Port Forwarding").font(.title2)
            Text(verbatim: controller.profile.displayName).foregroundStyle(.secondary)
            if controller.portForwardStatuses.isEmpty {
                Text("No rules configured. Edit the saved session to add forwarding rules, then reconnect.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(controller.portForwardStatuses) { status in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: status.rule.kind.title).font(.headline)
                                Text(verbatim: status.rule.summary).textSelection(.enabled)
                                HStack {
                                    Text(verbatim: status.state.title)
                                    Spacer()
                                    Text("Connections: \(status.connections)")
                                    if status.state == .listening || status.state == .starting {
                                        Button("Stop") { controller.stopPortForward(status.id) }
                                    } else {
                                        Button("Start") { controller.startPortForward(status.id) }
                                            .disabled(controller.state != .connected || status.state == .stopping)
                                    }
                                }
                                if let error = status.lastError {
                                    Text(verbatim: error).font(.caption).foregroundStyle(.orange)
                                }
                                Divider()
                            }
                        }
                    }
                }
                Text("Stopping a rule closes its forwarded connections, but keeps the terminal open. If a remote cancellation is not acknowledged within five seconds, SSH is closed for safety.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 580, height: 400)
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
