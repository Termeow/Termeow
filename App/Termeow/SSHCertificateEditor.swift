import AppKit
import SwiftUI
import TermeowKit

struct SSHCertificateEditor: View {
    @Binding var configuration: SSHCertificateConfiguration
    @Binding var validationFailure: String?
    let agentPublicKey: Data?
    @State private var certificate: SSHUserCertificate?
    @State private var loadFailure: String?
    @State private var loading = false
    @State private var reloadID = UUID()

    var body: some View {
        Toggle("Use OpenSSH User Certificate", isOn: $configuration.enabled)
            .task(id: LoadRequest(configuration: configuration, reloadID: reloadID)) { await load() }
            .onChange(of: validationError, initial: true) { validationFailure = validationError }
        if configuration.enabled {
            LabeledContent("User Certificate") {
                Button(configuration.fileName.isEmpty ? "Choose Certificate…" : configuration.fileName, action: choose)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button("Reload Certificate") { reloadID = UUID() }
                    .disabled(configuration.bookmark == nil || loading)
                Button("Remove Certificate") { configuration = SSHCertificateConfiguration() }
                if loading { ProgressView().controlSize(.small) }
            }
            if let certificate {
                detail("Certificate ID", certificate.keyID.isEmpty ? "(empty)" : certificate.keyID)
                detail("Serial", String(certificate.serial))
                detail("Key Type", certificate.publicKey.algorithm)
                detail("Key Fingerprint", certificate.publicKey.id)
                detail("CA Fingerprint", certificate.authority.id)
                detail("Valid From", certificate.validAfter == 0 ? "Any time" : date(certificate.validAfter))
                detail("Valid Until", certificate.validBefore == .max ? "No expiry" : date(certificate.validBefore))
                detail("Principals", certificate.principals.isEmpty ? "Any principal permitted by the server" : certificate.principals.joined(separator: ", "))
                if !certificate.criticalOptions.isEmpty {
                    detail("Critical Options", certificate.criticalOptions.keys.sorted().joined(separator: ", "))
                }
                detail("Permissions", certificate.extensions.keys.sorted().joined(separator: ", "))
                Text("The server decides which principals may log in and enforces certificate restrictions. A valid signature does not mean this server trusts the CA.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let validationError {
                Text(verbatim: validationError).font(.caption).foregroundStyle(.red)
            }
            Text("Choose a -cert.pub file matching your private key or selected agent key. The file is read again on every connection, including after renewal. Certificate failure never falls back to a plain key or password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var validationError: String? {
        guard configuration.enabled else { return nil }
        guard configuration.bookmark != nil else { return SSHCertificateError.missingFile.localizedDescription }
        if let loadFailure { return loadFailure }
        guard !loading, let certificate else { return "Reading certificate…" }
        do { try certificate.validate(matching: agentPublicKey); return nil }
        catch { return error.localizedDescription }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: display(value)).font(.caption.monospaced()).textSelection(.enabled)
                .lineLimit(3).help(display(value))
        } label: { Text(verbatim: label) }
    }

    private func display(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }.prefix(512).map(String.init).joined())
    }

    private func date(_ seconds: UInt64) -> String {
        // Avoid formatter overflow for certificates that use very distant validity bounds.
        guard seconds <= 253_402_300_799 else { return "Unix time \(seconds)" }
        return Date(timeIntervalSince1970: Double(seconds)).formatted(date: .abbreviated, time: .standard)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose OpenSSH User Certificate"
        panel.message = "Select the public -cert.pub file, not its private key."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            configuration = SSHCertificateConfiguration(enabled: true, bookmark: bookmark, fileName: url.lastPathComponent)
        } catch { loadFailure = SSHCertificateError.unreadableFile.localizedDescription }
    }

    private func load() async {
        certificate = nil; loadFailure = nil; loading = false
        guard configuration.enabled, configuration.bookmark != nil else { return }
        let selected = configuration
        loading = true
        do {
            let value = try await Task.detached { try selected.load() }.value
            guard !Task.isCancelled else { return }
            certificate = value
        } catch {
            guard !Task.isCancelled else { return }
            loadFailure = error.localizedDescription
        }
        loading = false
    }

    private struct LoadRequest: Equatable {
        let configuration: SSHCertificateConfiguration
        let reloadID: UUID
    }
}
