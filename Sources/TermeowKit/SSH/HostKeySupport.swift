import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

enum HostKeySupport {
    static func record(host: String, port: Int, key: NIOSSHPublicKey) -> HostKeyRecord {
        let openssh = String(openSSHPublicKey: key)
        let algorithm = openssh.split(separator: " ").first.map(String.init) ?? "unknown"
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)
        let digest = SHA256.hash(data: blob)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return HostKeyRecord(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprintSHA256: fingerprint,
            publicKeyBase64: Data(blob).base64EncodedString()
        )
    }
}

final class PromptingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let store: HostKeyStore
    private let prompt: HostKeyPromptHandler

    init(host: String, port: Int, store: HostKeyStore, prompt: @escaping HostKeyPromptHandler) {
        self.host = host
        self.port = port
        self.store = store
        self.prompt = prompt
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = HostKeySupport.record(host: host, port: port, key: hostKey)
        let loop = validationCompletePromise.futureResult.eventLoop
        Task {
            let result: Result<Void, Error>
            do {
                let check = try store.check(presented: presented)
                switch check {
                case .match:
                    result = .success(())
                case .unknown, .mismatch:
                    switch await prompt(check) {
                    case .cancel:
                        if case .mismatch = check {
                            result = .failure(SSHError.hostKeyChanged)
                        } else {
                            result = .failure(SSHError.hostKeyRejected)
                        }
                    case .connectOnce:
                        if case .mismatch = check {
                            AppLog.ssh.error("Host key mismatch accepted for this connection only")
                        }
                        result = .success(())
                    case .trustAndSave:
                        try store.upsert(presented)
                        result = .success(())
                    }
                }
            } catch {
                AppLog.ssh.error("Host key validation failed")
                result = .failure(error)
            }
            loop.execute {
                switch result {
                case .success:
                    validationCompletePromise.succeed(())
                case .failure(let error):
                    validationCompletePromise.fail(error)
                }
            }
        }
    }
}
