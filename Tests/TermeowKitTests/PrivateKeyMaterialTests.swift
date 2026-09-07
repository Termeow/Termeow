import Foundation
import Security
import Testing
@testable import TermeowKit

@Test func privateKeyAuthenticationAcceptsRSAPEM() throws {
    let pkcs1 = try makeRSAPKCS1Key()
    let pkcs1PEM = pem(label: "RSA PRIVATE KEY", data: pkcs1)
    _ = try CitadelConnectionFactory.privateKeyAuthentication(
        username: "test",
        keyText: pkcs1PEM,
        secret: ""
    )

    let pkcs8PEM = pem(label: "PRIVATE KEY", data: wrapRSAPKCS8(pkcs1))
    _ = try CitadelConnectionFactory.privateKeyAuthentication(
        username: "test",
        keyText: pkcs8PEM,
        secret: ""
    )
}

private enum PrivateKeyTestError: Error {
    case generationFailed
    case exportFailed
}

private func makeRSAPKCS1Key() throws -> Data {
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 2048,
        kSecAttrIsPermanent as String: false,
    ]
    var generationError: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &generationError) else {
        if let generationError { throw generationError.takeRetainedValue() }
        throw PrivateKeyTestError.generationFailed
    }
    var exportError: Unmanaged<CFError>?
    guard let data = SecKeyCopyExternalRepresentation(key, &exportError) as Data? else {
        if let exportError { throw exportError.takeRetainedValue() }
        throw PrivateKeyTestError.exportFailed
    }
    return data
}

private func wrapRSAPKCS8(_ pkcs1: Data) -> Data {
    let version = derElement(tag: 0x02, payload: Data([0]))
    let rsaEncryptionIdentifier = Data([
        0x30, 0x0d,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
        0x05, 0x00,
    ])
    let privateKey = derElement(tag: 0x04, payload: pkcs1)
    return derElement(tag: 0x30, payload: version + rsaEncryptionIdentifier + privateKey)
}

private func derElement(tag: UInt8, payload: Data) -> Data {
    var result = Data([tag])
    if payload.count < 128 {
        result.append(UInt8(payload.count))
    } else {
        var length = payload.count
        var bytes: [UInt8] = []
        while length > 0 {
            bytes.insert(UInt8(length & 0xff), at: 0)
            length >>= 8
        }
        result.append(0x80 | UInt8(bytes.count))
        result.append(contentsOf: bytes)
    }
    result.append(payload)
    return result
}

private func pem(label: String, data: Data) -> String {
    """
    -----BEGIN \(label)-----
    \(data.base64EncodedString())
    -----END \(label)-----
    """
}
