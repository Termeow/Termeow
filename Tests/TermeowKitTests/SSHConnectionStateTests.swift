import Testing
@testable import TermeowKit

@Test func onlyActiveSSHStatesRequireCloseConfirmation() {
    #expect(SSHConnectionState.connecting.requiresCloseConfirmation)
    #expect(SSHConnectionState.connected.requiresCloseConfirmation)
    #expect(!SSHConnectionState.disconnected.requiresCloseConfirmation)
    #expect(!SSHConnectionState.failed(.connectionFailed).requiresCloseConfirmation)
}
