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
        .sheet(item: Binding(
            get: { model.hostKeyPrompt },
            set: { if $0 == nil { model.resolveHostKey(.cancel) } }
        )) { prompt in
            HostKeyView(check: prompt.check)
        }
    }

    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly }
        )
    }

    private var detailColumn: some View {
        detailBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(model.selectedTab?.controller.title ?? "Termeow")
            .safeAreaInset(edge: .top, spacing: 0) { TabBarView() }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBarView() }
    }

    @ViewBuilder
    private var detailBody: some View {
        if let tab = model.selectedTab {
            TerminalContainerView(controller: tab.controller)
                .id(tab.controller.id)
        } else {
            EmptyTerminalView()
        }
    }
}

struct TabBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    TabChip(tab: tab, selected: tab.id == model.selectedTabID)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(.ultraThinMaterial)
    }
}

struct TabChip: View {
    @Environment(AppModel.self) private var model
    let tab: WorkspaceTab
    var selected: Bool

    var body: some View {
        Button {
            model.selectedTabID = tab.id
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(tab.controller.title)
                    .lineLimit(1)
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(connectionActionTitle, systemImage: "arrow.clockwise") {
                model.reconnectTab(tab.id)
            }
            .disabled(!tab.controller.canReconnect)
            Button("Disconnect", systemImage: "network.slash") {
                model.disconnectTab(tab.id)
            }
            .disabled(!tab.controller.canDisconnect)
            Button("Duplicate Tab", systemImage: "plus.square.on.square") {
                model.duplicateTab(tab.id)
            }
            Divider()
            Button("Close Tab", systemImage: "xmark") {
                model.closeTab(tab.id)
            }
            Button("Close Other Tabs", systemImage: "xmark.circle") {
                model.closeOtherTabs(keeping: tab.id)
            }
            .disabled(model.tabs.count < 2)
            Button("Close Tabs to the Right", systemImage: "arrow.right.to.line") {
                model.closeTabsToRight(of: tab.id)
            }
            .disabled(!model.hasTabsToRight(of: tab.id))
        }
    }

    private var connectionActionTitle: String {
        if case .disconnected = tab.controller.state {
            "Connect"
        } else {
            "Reconnect"
        }
    }

    private var color: Color {
        switch tab.controller.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let tab = model.selectedTab {
                Text("\(tab.controller.profile.host):\(tab.controller.profile.port)")
                Text(tab.controller.statusText)
                Text("\(tab.controller.cols)×\(tab.controller.rows)")
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
