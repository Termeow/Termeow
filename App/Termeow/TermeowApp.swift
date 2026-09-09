import AppKit
import SwiftUI
import TermeowKit

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

        Settings {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
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
        CommandMenu("Tab Groups") {
            Button("New Tab Group to the Right") { model.createGroup(.right) }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(model.selectedPaneCount >= 16)
            Button("New Tab Group Below") { model.createGroup(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.selectedPaneCount >= 16)
            Divider()
            Button("Focus Left Group") { model.focusGroup(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(model.selectedPaneCount < 2)
            Button("Focus Right Group") { model.focusGroup(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model.selectedPaneCount < 2)
            Button("Focus Group Above") { model.focusGroup(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(model.selectedPaneCount < 2)
            Button("Focus Group Below") { model.focusGroup(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model.selectedPaneCount < 2)
            Divider()
            Button(model.tabGroups.maximizedGroupID == nil ? "Maximize Tab Group" : "Restore Tab Groups") { model.toggleGroupZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.selectedPaneCount < 2)
            Button("Equalize Tab Groups") { model.equalizeGroups() }.disabled(model.selectedPaneCount < 2)
            Button("Merge All Tab Groups") { model.mergeAllGroups() }.disabled(model.selectedPaneCount < 2)
            Divider()
            Button("Close Tab Group") { model.requestCloseGroup(model.tabGroups.activeGroupID) }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model.findBarVisible = true }
                .keyboardShortcut("f", modifiers: [.command])
            Button("Find Next") { model.performFind(forward: true) }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(model.findQuery.isEmpty || model.selectedTab == nil)
            Button("Find Previous") { model.performFind(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.findQuery.isEmpty || model.selectedTab == nil)
            Divider()
            Button("Clear Screen") { model.clearSelectedTerminal() }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(model.selectedTab == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                model.sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button(model.statusBarVisible ? "Hide Status Bar" : "Show Status Bar") {
                model.statusBarVisible.toggle()
            }
            .keyboardShortcut("/", modifiers: [.command])
            Button("Open SFTP") { model.openSelectedSFTP() }
                .disabled(model.sftpContextProfile == nil)
            Divider()
            Button("Previous Tab") { model.selectRelativeTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { model.selectRelativeTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { position in
                Button(String(format: String(localized: "Select Tab %lld"), Int64(position))) {
                    model.selectTab(at: position - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(position))), modifiers: [.command])
                .disabled(!(model.tabGroups.activeGroup?.tabIDs.indices.contains(position - 1) ?? false))
            }
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
