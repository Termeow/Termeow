import AppKit
import SwiftUI
import TermeowKit

struct SSHAgentIdentityEditor: View {
    @Binding var configuration: SSHAgentConfiguration
    @State private var identities: [SSHAgentIdentity] = []
    @State private var request: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        TextField("Agent Socket", text: $configuration.socketPath, prompt: Text("SSH_AUTH_SOCK"))
            .help("Leave empty to use SSH_AUTH_SOCK, or paste an absolute socket path from OpenSSH, 1Password, or Secretive.")
            .onChange(of: configuration.socketPath) {
                cancel()
                identities = []; loaded = false; failure = nil
                configuration.publicKey = nil
            }
        HStack {
            Button(loaded ? "Refresh Agent Keys" : "Load Agent Keys", action: refresh)
                .disabled(request != nil)
            if request != nil {
                ProgressView().controlSize(.small)
                Button("Cancel Request", action: cancel)
            }
        }
        Picker("Agent Key", selection: $configuration.publicKey) {
            Text("Select a key...").tag(Data?.none)
            if let selected = configuration.identity, !identities.contains(where: { $0.blob == selected.blob }) {
                Text(verbatim: "Saved key — \(selected.algorithm) — \(selected.id)").tag(Optional(selected.blob))
            }
            ForEach(identities) { identity in
                Text(verbatim: label(identity))
                    .tag(Optional(identity.blob))
                    .disabled(!identity.isSupported)
            }
        }
        if let identity = configuration.identity {
            Text(verbatim: identity.id).font(.caption.monospaced()).textSelection(.enabled)
            Button("Copy Public Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(identity.authorizedKey, forType: .string)
            }
            if identity.algorithm == "ssh-rsa" {
                Toggle("Use RSA SHA-256 instead of SHA-512", isOn: $configuration.rsaSHA256)
                    .help("Use only if the server rejects RSA SHA-512. Legacy RSA/SHA-1 is never used.")
            }
            if loaded, !identities.contains(where: { $0.blob == identity.blob }) {
                Text("The saved key is not currently loaded in this agent. Load it in your agent or select another key before connecting.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        if let failure {
            Text(verbatim: failure).font(.caption).foregroundStyle(.red)
        } else if let validation = configuration.validationError {
            Text(verbatim: validation).font(.caption).foregroundStyle(.secondary)
        }
        if loaded, identities.isEmpty {
            Text("The agent has no keys. Add or unlock a key in your agent, then refresh.")
                .font(.caption).foregroundStyle(.secondary)
        } else if loaded, !identities.contains(where: \.isSupported) {
            Text("No supported keys found. Use Ed25519, RSA (2048-8192 bits), or ECDSA P-256/P-384/P-521. For certificate login, select the underlying plain key and choose its certificate file below. Security-key identities are not supported yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("Only this selected key is offered. Private keys stay in the agent. Approve any agent prompt within the session timeout (at most 120 seconds). This does not forward the agent to the server.")
            .font(.caption).foregroundStyle(.secondary)
            .onDisappear { cancel() }
    }

    private func label(_ identity: SSHAgentIdentity) -> String {
        let comment = identity.comment.isEmpty ? "" : "\(identity.comment.prefix(60)) — "
        return "\(comment)\(identity.algorithm) — \(identity.id)\(identity.isSupported ? "" : " (unsupported)")"
    }

    private func refresh() {
        cancel()
        let token = UUID()
        requestID = token
        let path = configuration.socketPath
        failure = nil; loaded = false; identities = []
        request = Task { @MainActor in
            do {
                let keys = try await SSHAgentClient.identities(socketPath: path)
                guard !Task.isCancelled, requestID == token else { return }
                identities = keys; loaded = true
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                failure = error.localizedDescription
            }
            request = nil
        }
    }

    private func cancel() {
        requestID = UUID()
        request?.cancel()
        request = nil
    }
}
