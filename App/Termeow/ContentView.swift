import SwiftUI
import TermeowKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.sidebarVisible {
                HSplitView {
                    SessionSidebar()
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                    detailColumn
                }
            } else {
                detailColumn
            }
        }
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

    private var detailColumn: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()
            detailBody
            Divider()
            StatusBarView()
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailBody: some View {
        if let tab = model.selectedTab {
            TerminalContainerView(controller: tab.controller)
                .id(tab.id)
        } else {
            EmptyTerminalView()
        }
    }
}

struct TabBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if !model.sidebarVisible {
                Button("Show Sessions") {
                    model.sidebarVisible = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == model.selectedTabID)
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .background(.bar)
    }
}

struct TabChip: View {
    @Environment(AppModel.self) private var model
    let tab: WorkspaceTab
    var selected: Bool

    var body: some View {
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
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTabID = tab.id }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

struct EmptyTerminalView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No terminal yet")
                .font(.title3)
            Text("Double-click a session to connect.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
