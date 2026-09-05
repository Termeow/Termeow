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
        case .unknown: "Unknown host key"
        case .mismatch: "Host key has changed"
        case .match: "Host key"
        }
    }

    private var bodyText: String {
        switch check {
        case .unknown(let record):
            "The authenticity of host '\(record.host):\(record.port)' can't be established.\n\n\(record.algorithm) key fingerprint:\n\(record.fingerprintSHA256)\n\nDo you want to continue connecting?"
        case .mismatch(let stored, let presented):
            "WARNING: remote host identification has changed for \(presented.host):\(presented.port).\n\nSaved: \(stored.algorithm) \(stored.fingerprintSHA256)\nOffered: \(presented.algorithm) \(presented.fingerprintSHA256)"
        case .match:
            "This host key is already trusted."
        }
    }
}
