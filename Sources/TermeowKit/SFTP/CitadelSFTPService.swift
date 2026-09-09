@preconcurrency import Citadel
import Foundation
import NIOCore

public enum SFTPServiceError: Error, Sendable {
    case notConnected
    case invalidName
    case localFileUnavailable
    case destinationTypeMismatch
}

public typealias SFTPTransferProgress = @Sendable (_ completedBytes: UInt64, _ totalBytes: UInt64?) -> Void

public actor CitadelSFTPService {
    private let profile: SessionProfile
    private let secret: String
    private let hostKeyStore: HostKeyStore
    private let prompt: HostKeyPromptHandler
    private let jumpHosts: [SSHConnectionHop]
    private var connection: CitadelConnection?
    private var sftpClient: Citadel.SFTPClient?
    private var connectTask: Task<CitadelConnection, Error>?
    private var connectionID: UUID?

    public init(
        profile: SessionProfile,
        secret: String,
        hostKeyStore: HostKeyStore,
        jumpHosts: [SSHConnectionHop] = [],
        prompt: @escaping HostKeyPromptHandler
    ) {
        self.profile = profile
        self.secret = secret
        self.hostKeyStore = hostKeyStore
        self.prompt = prompt
        self.jumpHosts = jumpHosts
    }

    public func connect() async throws -> String {
        if let sftpClient, sftpClient.isActive {
            return try await sftpClient.getRealPath(atPath: ".")
        }

        await disconnect()
        let id = UUID()
        connectionID = id
        let task = Task {
            try await CitadelConnectionFactory.connect(
                profile: profile, secret: secret, hostKeyStore: hostKeyStore,
                jumpHosts: jumpHosts, prompt: prompt
            )
        }
        connectTask = task
        defer { if connectionID == id { connectTask = nil } }
        let ssh = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        do {
            return try await withTaskCancellationHandler {
                guard connectionID == id else { throw CancellationError() }
                connection = ssh
                let sftp = try await ssh.client.openSFTP()
                let path = try await sftp.getRealPath(atPath: ".")
                try Task.checkCancellation()
                guard connectionID == id else { throw CancellationError() }
                connection = ssh
                sftpClient = sftp
                connectTask = nil
                return path
            } onCancel: { Task { await ssh.close() } }
        } catch {
            await ssh.close()
            if connectionID == id { connection = nil; connectionID = nil }
            throw error
        }
    }

    public func disconnect() async {
        connectionID = nil
        connectTask?.cancel()
        connectTask = nil
        let sftp = sftpClient
        let ssh = connection
        sftpClient = nil
        connection = nil
        try? await sftp?.close()
        await ssh?.close()
    }

    public func listDirectory(at path: String) async throws -> SFTPDirectory {
        let client = try connectedClient()
        let canonicalPath = try await client.getRealPath(atPath: path)
        let responses = try await client.listDirectory(atPath: canonicalPath)
        let items = responses
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                let permissions = component.attributes.permissions
                let kind = Self.itemKind(permissions: permissions, longName: component.longname)
                return SFTPItem(
                    name: component.filename,
                    path: SFTPPath.joining(canonicalPath, component.filename),
                    kind: kind,
                    size: component.attributes.size,
                    permissions: permissions,
                    modificationDate: component.attributes.accessModificationTime?.modificationTime
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return SFTPDirectory(path: canonicalPath, items: items)
    }

    public func createDirectory(at path: String) async throws {
        try await connectedClient().createDirectory(atPath: path)
    }

    public func renameItem(at oldPath: String, to newPath: String) async throws {
        try await connectedClient().rename(at: oldPath, to: newPath)
    }

    public func removeItem(at path: String, isDirectory: Bool) async throws {
        let client = try connectedClient()
        if isDirectory {
            try await client.rmdir(at: path)
        } else {
            try await client.remove(at: path)
        }
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        progress: SFTPTransferProgress? = nil
    ) async throws {
        let accessing = localURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { localURL.stopAccessingSecurityScopedResource() }
        }

        try await uploadFile(localURL: localURL, remotePath: remotePath, progress: progress)
    }

    public func uploadItem(
        localURL: URL,
        remotePath: String,
        progress: SFTPTransferProgress? = nil
    ) async throws {
        let accessing = localURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { localURL.stopAccessingSecurityScopedResource() }
        }

        try await uploadItemContents(localURL: localURL, remotePath: remotePath, progress: progress)
    }

    public func downloadItem(
        remoteItem: SFTPItem,
        localURL: URL,
        progress: SFTPTransferProgress? = nil
    ) async throws {
        let accessing = localURL.deletingLastPathComponent().startAccessingSecurityScopedResource()
        defer {
            if accessing { localURL.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
        }

        try await downloadItemContents(remoteItem: remoteItem, localURL: localURL, progress: progress)
    }

    private func uploadItemContents(
        localURL: URL,
        remotePath: String,
        progress: SFTPTransferProgress?
    ) async throws {
        try Task.checkCancellation()
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
            try await ensureRemoteDirectory(at: remotePath)
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                try await uploadItemContents(
                    localURL: child,
                    remotePath: SFTPPath.joining(remotePath, child.lastPathComponent),
                    progress: progress
                )
            }
        } else {
            try await uploadFile(localURL: localURL, remotePath: remotePath, progress: progress)
        }
    }

    private func uploadFile(
        localURL: URL,
        remotePath: String,
        progress: SFTPTransferProgress?
    ) async throws {
        let client = try connectedClient()

        guard let source = try? FileHandle(forReadingFrom: localURL) else {
            throw SFTPServiceError.localFileUnavailable
        }
        defer { try? source.close() }
        let values = try? localURL.resourceValues(forKeys: [.fileSizeKey])
        let total = values?.fileSize.map(UInt64.init)
        let remoteFile = try await client.openFile(
            filePath: remotePath,
            flags: [.write, .create, .truncate]
        )
        var offset: UInt64 = 0
        progress?(offset, total)

        do {
            while let data = try source.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try await remoteFile.write(ByteBuffer(data: data), at: offset)
                offset += UInt64(data.count)
                progress?(offset, total)
            }
            try await remoteFile.close()
        } catch {
            try? await remoteFile.close()
            throw error
        }
    }

    public func download(
        remotePath: String,
        localURL: URL,
        progress: SFTPTransferProgress? = nil
    ) async throws {
        let accessing = localURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { localURL.stopAccessingSecurityScopedResource() }
        }

        try await downloadFile(remotePath: remotePath, localURL: localURL, progress: progress)
    }

    private func downloadItemContents(
        remoteItem: SFTPItem,
        localURL: URL,
        progress: SFTPTransferProgress?
    ) async throws {
        try Task.checkCancellation()
        if remoteItem.isDirectory {
            if FileManager.default.fileExists(atPath: localURL.path) {
                let values = try localURL.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { throw SFTPServiceError.destinationTypeMismatch }
            } else {
                try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false)
            }
            let directory = try await listDirectory(at: remoteItem.path)
            for child in directory.items {
                try await downloadItemContents(
                    remoteItem: child,
                    localURL: localURL.appendingPathComponent(child.name, isDirectory: child.isDirectory),
                    progress: progress
                )
            }
        } else {
            try await downloadFile(remotePath: remoteItem.path, localURL: localURL, progress: progress)
        }
    }

    private func downloadFile(
        remotePath: String,
        localURL: URL,
        progress: SFTPTransferProgress?
    ) async throws {
        let client = try connectedClient()

        let attributes = try? await client.getAttributes(at: remotePath)
        let total = attributes?.size
        let destinationDirectory = localURL.deletingLastPathComponent()
        let temporaryURL = destinationDirectory.appendingPathComponent(".termeow-\(UUID().uuidString).download")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw SFTPServiceError.localFileUnavailable
        }
        let destination = try FileHandle(forWritingTo: temporaryURL)
        let remoteFile = try await client.openFile(filePath: remotePath, flags: .read)
        var offset: UInt64 = 0
        progress?(offset, total)

        do {
            while true {
                try Task.checkCancellation()
                let buffer = try await remoteFile.read(from: offset, length: 1_048_576)
                guard buffer.readableBytes > 0 else { break }
                let data = Data(buffer.readableBytesView)
                try destination.write(contentsOf: data)
                offset += UInt64(data.count)
                progress?(offset, total)
            }
            try destination.close()
            try await remoteFile.close()
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: localURL)
            }
        } catch {
            try? destination.close()
            try? await remoteFile.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func ensureRemoteDirectory(at path: String) async throws {
        let client = try connectedClient()
        if let attributes = try? await client.getAttributes(at: path) {
            guard let permissions = attributes.permissions,
                  permissions & 0o170000 == 0o040000 else {
                throw SFTPServiceError.destinationTypeMismatch
            }
            return
        }
        try await client.createDirectory(atPath: path)
    }

    private func connectedClient() throws -> Citadel.SFTPClient {
        guard let sftpClient, sftpClient.isActive else { throw SFTPServiceError.notConnected }
        return sftpClient
    }

    private static func itemKind(permissions: UInt32?, longName: String) -> SFTPItemKind {
        if let permissions {
            switch permissions & 0o170000 {
            case 0o040000: return .directory
            case 0o120000: return .symbolicLink
            default: return .file
            }
        }
        if longName.first == "d" { return .directory }
        if longName.first == "l" { return .symbolicLink }
        return .file
    }
}
