import CryptoKit
import Foundation

/// Just enough RFC 6455 for the mock's PTY sockets: the upgrade handshake, unmasking client frames (with
/// fragmentation, ping and close) and writing unmasked server frames.
enum WebSocket {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    enum Opcode: UInt8 {
        case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
    }

    /// Whether a request asks to upgrade to a WebSocket.
    static func isUpgrade(_ request: HTTPRequest) -> Bool {
        request.headers["upgrade"]?.lowercased() == "websocket" && request.headers["sec-websocket-key"] != nil
    }

    /// The `101 Switching Protocols` response for a request with `Sec-WebSocket-Key`.
    static func handshake(key: String) -> Data {
        let accept = Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
        let head = [
            "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
        ]
        return Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// An unmasked server frame (FIN set).
    static func frame(_ opcode: Opcode, _ payload: Data) -> Data {
        var data = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            data.append(UInt8(count))
        } else if count <= 0xFFFF {
            data.append(126)
            data.append(UInt8(count >> 8))
            data.append(UInt8(count & 0xFF))
        } else {
            data.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((count >> shift) & 0xFF)) }
        }
        data.append(payload)
        return data
    }

    static func text(_ string: String) -> Data { frame(.text, Data(string.utf8)) }

    static func close(code: UInt16, reason: String) -> Data {
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8.prefix(120)))
        return frame(.close, payload)
    }

    /// A complete message from the client.
    enum Message: Equatable {
        case text(String)
        case binary(Data)
        case ping(Data)
        case close(code: UInt16?)
    }

    /// Incremental client-frame parser. Feed bytes; take messages out.
    struct Parser {
        private var buffer = Data()
        private var fragments = Data()
        private var fragmentOpcode: Opcode?
        static let maxMessage = 16 << 20

        mutating func append(_ data: Data) { buffer.append(data) }

        enum Failure: Error { case protocolError, tooLarge }

        mutating func next() throws(Failure) -> Message? {
            while true {
                let bytes = [UInt8](buffer.prefix(14))
                guard bytes.count >= 2 else { return nil }
                let fin = bytes[0] & 0x80 != 0
                guard let opcode = Opcode(rawValue: bytes[0] & 0x0F) else { throw .protocolError }
                let masked = bytes[1] & 0x80 != 0
                var length = Int(bytes[1] & 0x7F)
                var offset = 2
                if length == 126 {
                    guard bytes.count >= 4 else { return nil }
                    length = Int(bytes[2]) << 8 | Int(bytes[3])
                    offset = 4
                } else if length == 127 {
                    guard bytes.count >= 10 else { return nil }
                    length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[$1]) }
                    offset = 10
                }
                guard length <= Self.maxMessage else { throw .tooLarge }
                let maskLength = masked ? 4 : 0
                guard buffer.count >= offset + maskLength + length else { return nil }
                let start = buffer.startIndex
                let mask = masked ? [UInt8](buffer[(start + offset)..<(start + offset + 4)]) : []
                var payload = [UInt8](buffer[(start + offset + maskLength)..<(start + offset + maskLength + length)])
                if masked { for index in payload.indices { payload[index] ^= mask[index & 3] } }
                buffer = Data(buffer[(start + offset + maskLength + length)...])

                switch opcode {
                case .ping: return .ping(Data(payload))
                case .pong: continue
                case .close:
                    let code = payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil
                    return .close(code: code)
                case .continuation:
                    guard let first = fragmentOpcode else { throw .protocolError }
                    fragments.append(contentsOf: payload)
                    guard fragments.count <= Self.maxMessage else { throw .tooLarge }
                    guard fin else { continue }
                    let data = fragments
                    fragments = Data()
                    fragmentOpcode = nil
                    return first == .text ? .text(String(decoding: data, as: UTF8.self)) : .binary(data)
                case .text, .binary:
                    guard fin else {
                        fragmentOpcode = opcode
                        fragments = Data(payload)
                        continue
                    }
                    return opcode == .text ? .text(String(decoding: payload, as: UTF8.self)) : .binary(Data(payload))
                }
            }
        }
    }
}
