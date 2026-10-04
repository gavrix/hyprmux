import Foundation

/// The control socket: one line out, one reply back, the same protocol `hyprmuxctl` speaks.
enum HyprmuxSocket {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func request(_ line: String, path: String) throws -> Data {
        let fd = try connected(path)
        defer { close(fd) }
        try send(line, to: fd)

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n < 0 { throw Failure(description: "no reply from Hyprmux") }
            if n == 0 { break }
            output.append(buffer, count: n)
        }
        if output.starts(with: Data("error:".utf8)) {
            throw Failure(description: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    /// Subscribes to events. Read lines from the returned descriptor; EOF means Hyprmux quit.
    static func subscribe(path: String) throws -> Int32 {
        let fd = try connected(path)
        do {
            try send("events", to: fd)
        } catch {
            close(fd)
            throw error
        }
        // Events come whenever they come: no read timeout here.
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func connected(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket() failed") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A busy main thread in Hyprmux shouldn't hang the tour.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                memcpy(buffer.baseAddress!, source.baseAddress!, min(buffer.count - 1, source.count))
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw Failure(description: "can't connect to \(path)")
        }
        return fd
    }

    private static func send(_ line: String, to fd: Int32) throws {
        let request = Array((line + "\n").utf8)
        var offset = 0
        while offset < request.count {
            let n = request[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw Failure(description: "write failed") }
            offset += n
        }
        shutdown(fd, SHUT_WR)
    }
}
