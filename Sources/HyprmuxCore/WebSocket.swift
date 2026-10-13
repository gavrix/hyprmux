import CryptoKit
import Foundation

// The server half of RFC 6455, enough for CDP clients: the HTTP upgrade, then text
// messages, pings, and close. No extensions (no compression), no subprotocols.

public enum WebSocketHandshake {
    public struct Request: Equatable, Sendable {
        public let path: String
        public let key: String
        /// Header names lowercased.
        public let headers: [String: String]
    }

    /// The largest request head accepted, so a client can't grow the buffer without end.
    public static let maximumHeadBytes = 16 * 1024

    /// Parses an HTTP request head. Nil while `data` doesn't hold the whole head yet.
    /// On success also returns how many bytes the head used.
    public static func parse(_ data: Data) -> Result<(Request, Int)?, ParseError> {
        let end = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: end) else {
            return data.count > maximumHeadBytes ? .failure(ParseError("request head too large")) : .success(nil)
        }
        guard range.lowerBound <= maximumHeadBytes,
              let head = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else {
            return .failure(ParseError("invalid request head"))
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[0] == "GET", requestLine[2].hasPrefix("HTTP/1.") else {
            return .failure(ParseError("expected a GET request"))
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .failure(ParseError("invalid header")) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",")
                .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true else {
            return .failure(ParseError("not a WebSocket upgrade"))
        }
        guard headers["sec-websocket-version"] == "13" else {
            return .failure(ParseError("unsupported WebSocket version"))
        }
        guard let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
            return .failure(ParseError("invalid Sec-WebSocket-Key"))
        }
        let consumed = data.distance(from: data.startIndex, to: range.upperBound)
        return .success((Request(path: String(requestLine[1]), key: key, headers: headers), consumed))
    }

    /// Why a local-only endpoint refuses a request, or nil to accept it.
    ///
    /// Web pages can open WebSockets to localhost, so a request with an `Origin` is refused,
    /// as Chrome refuses one without `--remote-allow-origins`. The `Host` must name the
    /// loopback address, so DNS rebinding can't reach the endpoint either.
    public static func refusal(_ request: Request, port: UInt16) -> String? {
        if let origin = request.headers["origin"], !origin.isEmpty { return "requests from web pages are refused" }
        let allowed = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowed.contains(host) else {
            return "the Host header must name the loopback address"
        }
        return nil
    }

    public static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    public static func accept(_ request: Request) -> Data {
        Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Accept: \(acceptValue(for: request.key))\r\n\r\n").utf8)
    }

    public static func reject(status: Int, _ reason: String) -> Data {
        let text = reason + "\n"
        let title = status == 403 ? "Forbidden" : status == 404 ? "Not Found" : "Bad Request"
        return Data(("HTTP/1.1 \(status) \(title)\r\nContent-Type: text/plain; charset=utf-8\r\n"
                     + "Content-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n" + text).utf8)
    }
}

public enum WebSocketMessage: Equatable, Sendable {
    case text(Data)
    case binary(Data)
    case ping(Data)
    case pong
    /// The peer is closing; reply with a close frame and drop the connection.
    case close(UInt16?)
}

/// Turns client bytes into messages. Client frames must be masked.
public struct WebSocketDecoder {
    public var maximumMessageBytes: Int
    private var buffer = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8?

    public init(maximumMessageBytes: Int = 256 * 1024 * 1024) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    public mutating func push(_ data: Data) -> Result<[WebSocketMessage], ParseError> {
        buffer.append(data)
        var messages: [WebSocketMessage] = []
        while true {
            switch nextFrame() {
            case .failure(let e): return .failure(e)
            case .success(nil): return .success(messages)
            case .success(let (fin, opcode, payload)?):
                switch opcode {
                case 0x0:
                    guard let op = fragmentOpcode else { return .failure(ParseError("unexpected continuation frame")) }
                    fragments.append(payload)
                    guard fragments.count <= maximumMessageBytes else { return .failure(ParseError("message too large")) }
                    if fin {
                        messages.append(op == 0x1 ? .text(fragments) : .binary(fragments))
                        fragments = Data()
                        fragmentOpcode = nil
                    }
                case 0x1, 0x2:
                    guard fragmentOpcode == nil else { return .failure(ParseError("interleaved data frames")) }
                    if fin {
                        messages.append(opcode == 0x1 ? .text(payload) : .binary(payload))
                    } else {
                        fragmentOpcode = opcode
                        fragments = payload
                    }
                case 0x8:
                    let code = payload.count >= 2 ? UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]) : nil
                    messages.append(.close(code))
                    return .success(messages)
                case 0x9: messages.append(.ping(payload))
                case 0xA: messages.append(.pong)
                default: return .failure(ParseError("unknown opcode \(opcode)"))
                }
            }
        }
    }

    private mutating func nextFrame() -> Result<(Bool, UInt8, Data)?, ParseError> {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return .success(nil) }
        let fin = bytes[0] & 0x80 != 0
        guard bytes[0] & 0x70 == 0 else { return .failure(ParseError("reserved bits set")) }
        let opcode = bytes[0] & 0x0F
        guard bytes[1] & 0x80 != 0 else { return .failure(ParseError("client frames must be masked")) }
        var length = UInt64(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return .success(nil) }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return .success(nil) }
            length = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
            offset = 10
        }
        if opcode >= 0x8 { guard fin, length <= 125 else { return .failure(ParseError("invalid control frame")) } }
        guard length <= UInt64(maximumMessageBytes) else { return .failure(ParseError("message too large")) }
        guard bytes.count >= offset + 4 else { return .success(nil) }
        let mask = Array(bytes[offset..<offset + 4])
        offset += 4
        guard buffer.count >= offset + Int(length) else { return .success(nil) }
        let start = buffer.index(buffer.startIndex, offsetBy: offset)
        var payload = Data(buffer[start..<buffer.index(start, offsetBy: Int(length))])
        payload.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<raw.count { p[i] ^= mask[i & 3] }
        }
        buffer.removeSubrange(buffer.startIndex..<buffer.index(start, offsetBy: Int(length)))
        return .success((fin, opcode, payload))
    }
}

public enum WebSocketEncoder {
    /// One unmasked frame, as a server sends: 0x1 text, 0x8 close, 0x9 ping, 0xA pong.
    public static func frame(opcode: UInt8, _ payload: Data) -> Data {
        var head: [UInt8] = [0x80 | opcode]
        switch payload.count {
        case ..<126: head.append(UInt8(payload.count))
        case ..<65536: head += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            head.append(127)
            head += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (UInt64($0) * 8)) & 0xFF) }
        }
        return Data(head) + payload
    }

    public static func text(_ payload: Data) -> Data { frame(opcode: 0x1, payload) }

    public static func close(_ code: UInt16 = 1000) -> Data {
        frame(opcode: 0x8, Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }
}
