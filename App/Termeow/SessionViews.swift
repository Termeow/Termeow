import AppKit
import SwiftUI
import TermeowKit

struct SessionSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button("Add", systemImage: "plus") {
                    model.beginNewSession()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New Session")
                Button("Hide Sessions", systemImage: "sidebar.left") {
                    model.sidebarVisible = false
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide Sessions")
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.bar)

            Divider()

            List(selection: $model.selectedProfileID) {
                ForEach(model.groupedProfiles, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.profiles) { profile in
                            SessionRow(profile: profile)
                                .tag(profile.id)
                                .contextMenu { sessionMenu(profile) }
                                .onTapGesture(count: 2) {
                                    model.selectedProfileID = profile.id
                                    model.connectSelected()
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func sessionMenu(_ profile: SessionProfile) -> some View {
        Button("Connect") {
            model.selectedProfileID = profile.id
            model.connectSelected()
        }
        Button("New Tab") {
            model.selectedProfileID = profile.id
            model.openSelectedInNewTab()
        }
        Divider()
        Button("Edit") {
            model.selectedProfileID = profile.id
            model.editSelected()
        }
        Button("Duplicate") {
            model.selectedProfileID = profile.id
            model.duplicateSelected()
        }
        Button("Delete", role: .destructive) {
            model.selectedProfileID = profile.id
            model.deleteSelected()
        }
    }
}

struct SessionRow: View {
    let profile: SessionProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.displayName).lineLimit(1)
            Text("\(profile.username)@\(profile.host):\(profile.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct SessionEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var state: SessionEditorState

    init(state: SessionEditorState) {
        _state = State(initialValue: state)
    }

    var body: some View {
        NavigationStack {
            SessionEditorForm(state: $state) {
                model.editor = nil
            } onSave: {
                model.editor = state
                model.saveEditor()
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

struct SessionEditorForm: View {
    @Binding var state: SessionEditorState
    var onCancel: () -> Void
    var onSave: () -> Void
    @State private var keyPath = ""

    var body: some View {
        Form {
            TextField("Name", text: $state.profile.name)
            TextField("Host", text: $state.profile.host)
            TextField("Port", value: $state.profile.port, format: .number)
            TextField("Username", text: $state.profile.username)
            Picker("Authentication", selection: $state.profile.authMethod) {
                ForEach(AuthMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            if state.profile.authMethod == .password {
                SecureField("Password", text: $state.secret)
            } else {
                SecureField("Passphrase", text: $state.secret)
                HStack {
                    Text(keyPath.isEmpty ? keyLabel : keyPath)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseKey() }
                }
            }
            TextField("Startup Command", text: $state.profile.startupCommand)
            TextField("Group", text: $state.profile.groupName)
            DisclosureGroup("Advanced") {
                TextField("TERM", text: $state.profile.term)
                TextField("Timeout", value: $state.profile.timeoutSeconds, format: .number)
                TextField("KeepAlive", value: $state.profile.keepAliveSeconds, format: .number)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Session")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: onSave)
                    .disabled(state.profile.host.isEmpty || state.profile.username.isEmpty)
            }
        }
    }

    private var keyLabel: String {
        state.profile.privateKeyBookmark == nil ? "No key selected" : "Key bookmark saved"
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Private Key"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            state.profile.privateKeyBookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            keyPath = url.path
        } catch {
            AppLog.storage.error("Could not create key bookmark")
        }
    }
}
