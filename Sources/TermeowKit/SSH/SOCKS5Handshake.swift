import NIOCore

struct SOCKS5Failure: Error {
    let reply: [UInt8]
    init(code: UInt8) { reply = [5, code, 0, 1, 0, 0, 0, 0, 0, 0] }
    init(reply: [UInt8]) { self.reply = reply }
}

/// Incremental SOCKS5 CONNECT parser. DNS names are forwarded unchanged for remote resolution.
struct SOCKS5Handshake {
    enum Message: Equatable {
        case reply([UInt8])
        case connect(String, Int)
    }
    private var greeted = false
    private var complete = false

    mutating func next(from buffer: inout ByteBuffer) throws -> Message? {
        guard !complete else { return nil }
        let start = buffer.readerIndex
        if !greeted {
            guard let version: UInt8 = buffer.getInteger(at: start),
                  let count: UInt8 = buffer.getInteger(at: start + 1) else { return nil }
            guard version == 5, count > 0 else { throw SOCKS5Failure(reply: [5, 255]) }
            guard let methods = buffer.getBytes(at: start + 2, length: Int(count)) else { return nil }
            guard methods.contains(0) else { throw SOCKS5Failure(reply: [5, 255]) }
            buffer.moveReaderIndex(forwardBy: 2 + Int(count))
            greeted = true
            return .reply([5, 0])
        }
        guard let header = buffer.getBytes(at: start, length: 4) else { return nil }
        guard header[0] == 5, header[2] == 0 else { throw SOCKS5Failure(code: 1) }
        guard header[1] == 1 else { throw SOCKS5Failure(code: 7) }
        let host: String
        let addressSize: Int
        switch header[3] {
        case 1:
            guard let bytes = buffer.getBytes(at: start + 4, length: 4) else { return nil }
            host = bytes.map(String.init).joined(separator: ".")
            addressSize = 4
        case 3:
            guard let length: UInt8 = buffer.getInteger(at: start + 4) else { return nil }
            guard length > 0 else { throw SOCKS5Failure(code: 8) }
            guard let bytes = buffer.getBytes(at: start + 5, length: Int(length)) else { return nil }
            guard let name = String(bytes: bytes, encoding: .utf8), PortForwardRule.validDestination(name) else {
                throw SOCKS5Failure(code: 8)
            }
            host = name
            addressSize = 1 + Int(length)
        case 4:
            guard let bytes = buffer.getBytes(at: start + 4, length: 16) else { return nil }
            host = stride(from: 0, to: 16, by: 2).map {
                String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16)
            }.joined(separator: ":")
            addressSize = 16
        default: throw SOCKS5Failure(code: 8)
        }
        guard let port: UInt16 = buffer.getInteger(at: start + 4 + addressSize) else { return nil }
        guard port > 0 else { throw SOCKS5Failure(code: 1) }
        buffer.moveReaderIndex(forwardBy: 6 + addressSize)
        complete = true
        return .connect(host, Int(port))
    }
}
