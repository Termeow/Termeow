import Foundation
import Testing
@testable import TermeowKit

@Test func keychainSaveReadDelete() throws {
    let store = KeychainStore(service: "cn.termeow.Termeow.tests")
    let id = UUID()
    defer { try? store.deleteSecret(id: id) }

    try store.saveSecret("not-a-real-password", id: id)
    #expect(try store.secret(id: id) == "not-a-real-password")
    try store.deleteSecret(id: id)
    #expect(try store.secret(id: id) == nil)
}
