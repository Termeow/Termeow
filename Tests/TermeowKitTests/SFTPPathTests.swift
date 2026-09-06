import Foundation
import Testing
@testable import TermeowKit

@Test func sftpPathJoiningHandlesRootAndTrailingSlashes() {
    #expect(SFTPPath.joining("/", "file.txt") == "/file.txt")
    #expect(SFTPPath.joining("/var/tmp", "file.txt") == "/var/tmp/file.txt")
    #expect(SFTPPath.joining("/var/tmp/", "file.txt") == "/var/tmp/file.txt")
}

@Test func sftpPathParentStopsAtRoot() {
    #expect(SFTPPath.parent(of: "/") == "/")
    #expect(SFTPPath.parent(of: "/root") == "/")
    #expect(SFTPPath.parent(of: "/root/uploads") == "/root")
}

@Test func sftpNamesRejectUnsafePathComponents() {
    #expect(SFTPPath.isValidName("archive.zip"))
    #expect(SFTPPath.isValidName("résumé.pdf"))
    #expect(!SFTPPath.isValidName(""))
    #expect(!SFTPPath.isValidName("."))
    #expect(!SFTPPath.isValidName(".."))
    #expect(!SFTPPath.isValidName("nested/file"))
    #expect(!SFTPPath.isValidName("bad\nname"))
}

@Test func sftpItemIdentityAndDirectoryMetadata() {
    let item = SFTPItem(
        name: "uploads",
        path: "/root/uploads",
        kind: .directory,
        size: 4_096,
        permissions: 0o040755,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(item.id == "/root/uploads")
    #expect(item.isDirectory)
    #expect(item.permissions == 0o040755)
}
