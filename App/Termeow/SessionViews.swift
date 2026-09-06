import AppKit
import SwiftUI
import TermeowKit

struct SessionSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedProfileID) {
            ForEach(model.groupedProfiles, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.profiles) { profile in
                        let selected = model.selectedProfileID == profile.id
                        SessionRow(profile: profile, selected: selected)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                selected ? Color.blue : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .onTapGesture {
                                model.selectedProfileID = profile.id
                            }
                            .simultaneousGesture(
                                TapGesture(count: 2)
                                    .onEnded { model.connect(profile) }
                            )
                            .tag(profile.id)
                            .contextMenu { sessionMenu(profile) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(.blue)
        .navigationTitle("Sessions")
        .searchable(text: $model.searchText, prompt: "Sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") {
                    model.beginNewSession()
                }
                .help("New Session")
            }
        }
    }

    @ViewBuilder
    private func sessionMenu(_ profile: SessionProfile) -> some View {
        Button("Connect") {
            model.connect(profile)
        }
        Button("Open SFTP") {
            model.openSFTP(profile)
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
    let selected: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).lineLimit(1)
                Text(verbatim: "\(profile.username)@\(profile.host):\(profile.port)")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "server.rack")
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
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
            Section("Connection") {
                TextField("Name", text: $state.profile.name)
                TextField("Host", text: $state.profile.host)
                TextField("Port", value: $state.profile.port, format: .number)
                if !SessionProfile.validPortRange.contains(state.profile.port) {
                    validationMessage("Port must be between 1 and 65535.")
                }
                TextField("Username", text: $state.profile.username)
            }
            Section("Authentication") {
                Picker("Method", selection: $state.profile.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                if state.profile.authMethod == .password {
                    SecureField("Password", text: $state.secret)
                } else {
                    SecureField("Passphrase", text: $state.secret)
                    LabeledContent("Private Key") {
                        Button(keyPath.isEmpty ? keyLabel : keyPath) { chooseKey() }
                    }
                }
            }
            Section {
                TextField("Startup Command", text: $state.profile.startupCommand)
                TextField("Group", text: $state.profile.groupName)
            }
            Section("Advanced") {
                TextField("TERM", text: $state.profile.term)
                TextField("Timeout", value: $state.profile.timeoutSeconds, format: .number)
                if state.profile.timeoutSeconds <= 0 {
                    validationMessage("Timeout must be at least 1 second.")
                }
                TextField("Keep Alive", value: $state.profile.keepAliveSeconds, format: .number)
                if state.profile.keepAliveSeconds < 0 {
                    validationMessage("Keep Alive must be 0 or greater.")
                }
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
                    .disabled(!state.profile.isValidForSaving)
            }
        }
    }

    private func validationMessage(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }

    private var keyLabel: String {
        state.profile.privateKeyBookmark == nil
            ? String(localized: "Choose…")
            : String(localized: "Key bookmark saved")
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose Private Key")
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
