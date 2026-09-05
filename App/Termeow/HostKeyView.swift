import SwiftUI
import TermeowKit

struct HostKeyView: View {
    @Environment(AppModel.self) private var model
    let check: HostKeyCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            Text(bodyText)
                .textSelection(.enabled)
                .font(.body)
            if isMismatch {
                Text("The host key does not match the saved key. An attacker may be intercepting this connection.")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.resolveHostKey(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button("Connect Once") { model.resolveHostKey(.connectOnce) }
                Button("Trust and Save") { model.resolveHostKey(.trustAndSave) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    private var isMismatch: Bool {
        if case .mismatch = check { return true }
        return false
    }

    private var title: String {
        switch check {
        case .unknown: String(localized: "Unknown host key")
        case .mismatch: String(localized: "Host key has changed")
        case .match: String(localized: "Host key")
        }
    }

    private var bodyText: String {
        switch check {
        case .unknown(let record):
            String(
                format: String(localized: "The authenticity of host '%@:%ld' can't be established.\n\n%@ key fingerprint:\n%@\n\nDo you want to continue connecting?"),
                locale: Locale.current,
                record.host,
                record.port,
                record.algorithm,
                record.fingerprintSHA256
            )
        case .mismatch(let stored, let presented):
            String(
                format: String(localized: "WARNING: remote host identification has changed for %@:%ld.\n\nSaved: %@ %@\nOffered: %@ %@"),
                locale: Locale.current,
                presented.host,
                presented.port,
                stored.algorithm,
                stored.fingerprintSHA256,
                presented.algorithm,
                presented.fingerprintSHA256
            )
        case .match:
            String(localized: "This host key is already trusted.")
        }
    }
}
