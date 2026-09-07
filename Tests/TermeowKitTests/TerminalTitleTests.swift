import Foundation
import Testing
@testable import TermeowKit

@Test func terminalTitlePolicyNormalizesRemoteTitles() {
    #expect(TerminalTitlePolicy.displayTitle(from: "  deploy\n\tserver  ") == "deploy server")
    #expect(TerminalTitlePolicy.displayTitle(from: "\u{0}\u{7}") == nil)
}

@Test func terminalTitlePolicyCapsLongTitles() {
    let title = String(repeating: "猫", count: TerminalTitlePolicy.maximumLength + 10)
    #expect(TerminalTitlePolicy.displayTitle(from: title)?.count == TerminalTitlePolicy.maximumLength)
}

@Test @MainActor func terminalViewForwardsOSCTitle() {
    let view = SSHTerminalView()
    var receivedTitle: String?
    view.onTitleChanged = { receivedTitle = $0 }

    view.feedOutput(Data("\u{1b}]0;build@server\u{7}".utf8))

    #expect(receivedTitle == "build@server")
}
