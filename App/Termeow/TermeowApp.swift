import AppKit
import SwiftUI

@main
struct TermeowApp: App {
    @State private var model = AppModel()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands(model: model)
        }
    }
}

struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { model.beginNewSession() }
                .keyboardShortcut("n", modifiers: [.command])
            Button("New Tab") { model.openSelectedInNewTab() }
                .keyboardShortcut("t", modifiers: [.command])
            Button("Close Tab") { model.closeSelectedTabOrSFTPWindow() }
                .keyboardShortcut("w", modifiers: [.command])
        }
        CommandMenu("Session") {
            Button("Connect") { model.connectSelected() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selectedProfile == nil)
            Button("Disconnect") { model.disconnectSelectedTab() }
                .disabled(model.selectedTab?.controller.canDisconnect != true)
            Button("Open SFTP") { model.openSelectedSFTP() }
                .disabled(model.sftpContextProfile == nil)
            Divider()
            Button(model.selectedProfile?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let profile = model.selectedProfile {
                    model.toggleFavorite(profile)
                }
            }
            .disabled(model.selectedProfile == nil)
            Button("Copy SSH Command") {
                if let profile = model.selectedProfile {
                    model.copySSHCommand(profile)
                }
            }
            .disabled(model.selectedProfile == nil)
            Divider()
            Button("Edit Session…") { model.editSelected() }
                .disabled(model.selectedProfile == nil)
            Button("Duplicate Session") { model.duplicateSelected() }
                .disabled(model.selectedProfile == nil)
            Button("Delete Session") { model.deleteSelected() }
                .disabled(model.selectedProfile == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model.findBarVisible = true }
                .keyboardShortcut("f", modifiers: [.command])
        }
        CommandGroup(after: .sidebar) {
            Button("Previous Tab") { model.selectRelativeTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { model.selectRelativeTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Termeow Help") {
                if let url = URL(string: "https://termeow.cn") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
