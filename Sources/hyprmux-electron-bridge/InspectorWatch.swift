// Reads the app's stderr while its main-process inspector is open
// (docs/ADAPTERS.md, "Security"). The app runs with --inspect-publish-uid=stderr, so
// the inspector's WebSocket URL appears only there, never on its HTTP endpoints. This
// reader takes the URL, counts the sessions the inspector reports, and forwards every
// line to the bridge's own stderr, which Hyprmux logs. The URL's secret part is
// redacted in what it forwards.
import Foundation

final class InspectorWatch {
    enum Event {
        /// The inspector reported a session ("Debugger attached."). The count includes it.
        case attached(Int)
        /// The hook closed the inspector. Counts every session it ever had.
        case closed(sessions: Int)
    }

    /// The line the hook writes to stderr right after `inspector.close()` returns. Every
    /// "Debugger attached." the inspector printed comes before it in the pipe.
    static let closedMarker = "hyprmux-hook: inspector closed"

    private let port: Int
    private let lock = NSLock()
    private var url: String?
    private var sessions = 0
    private var closed = false
    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    init(port: Int) { self.port = port }

    /// The inspector's WebSocket URL, once the app printed it.
    var webSocketURL: String? { lock.withLock { url } }

    /// Stop counting sessions: the inspector is closed, and later lines come from
    /// child processes (an extension host being debugged, say).
    func stopCounting() { lock.withLock { closed = true } }

    func start(reading fd: Int32) {
        let thread = Thread { [self] in readLoop(fd) }
        thread.name = "app stderr"
        thread.start()
    }

    private func readLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Data()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(contentsOf: buffer[0..<n])
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                handle(line)
            }
            // A runaway line without a newline: pass it on in pieces.
            if pending.count > 64 * 1024 {
                handle(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
        }
        if !pending.isEmpty { handle(String(decoding: pending, as: UTF8.self)) }
    }

    private func handle(_ line: String) {
        if line == Self.closedMarker {
            let count: Int? = lock.withLock {
                guard !closed else { return nil }
                closed = true
                return sessions
            }
            if let count { post(.closed(sessions: count)) }
            return
        }
        let prefix = "ws://127.0.0.1:\(port)/"
        if line.hasPrefix("Debugger listening on "), let start = line.range(of: prefix) {
            let found = String(line[start.lowerBound...].prefix { !$0.isWhitespace })
            lock.withLock { if url == nil { url = found } }
        } else if line.hasPrefix("Debugger attached.") {
            let count: Int? = lock.withLock {
                guard !closed else { return nil }
                sessions += 1
                return sessions
            }
            if let count { post(.attached(count)) }
        }
        stderr(redacted(line, prefix: prefix))
    }

    /// "Debugger listening on ws://127.0.0.1:PORT/UUID" without the UUID, which is
    /// what lets a client attach.
    private func redacted(_ line: String, prefix: String) -> String {
        guard line.hasPrefix("Debugger "), let start = line.range(of: prefix) else { return line }
        let rest = line[start.upperBound...]
        let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        return String(line[..<start.upperBound]) + "(hidden)" + String(rest[end...])
    }

    private func post(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}

/// Whether something accepts TCP connections on 127.0.0.1:port.
func loopbackPortAccepts(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    addr.sin_port = UInt16(port).bigEndian
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return rc == 0
}
