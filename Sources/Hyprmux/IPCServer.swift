import Foundation
import HyprmuxCore

/// A reply to one control-socket line. `background` work runs on the connection's
/// thread, not main, for requests that wait on something slow (an adapter probe).
enum IPCReply {
    case text(String)
    case background(() -> String)
}

/// Serves the control socket. Each connection sends one line and gets one reply,
/// except `events`: that connection stays open and receives every event as a line
/// (docs/HOOKS.md).
final class IPCServer {
    let path: String
    private var fd: Int32 = -1
    private let handler: (String) -> IPCReply
    /// Lines a new subscriber gets first: the current state of stateful events. Runs on main.
    var greeting: () -> [String] = { [] }

    /// One `events` connection. Writes happen on its own queue, so a slow reader never
    /// blocks the main thread; one that falls too far behind is dropped.
    private final class Subscriber {
        let fd: Int32
        let queue: DispatchQueue
        var pending = 0
        var closed = false
        init(fd: Int32, number: Int) {
            self.fd = fd
            queue = DispatchQueue(label: "hyprmux-events-\(number)")
        }
    }
    private let lock = NSLock()
    private var subscribers: [Subscriber] = []
    private var subscriberCount = 0
    private static let maximumPending = 1000

    init?(path: String, handler: @escaping (String) -> IPCReply) {
        self.path = path
        self.handler = handler
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { src in memcpy(buf.baseAddress!, src.baseAddress!, min(buf.count - 1, src.count)) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        guard chmod(path, 0o600) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "hyprmux-ipc"
        t.start()
    }

    deinit {
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            let maximumRequestBytes = 1024 * 1024
            var tooLarge = false
            while !data.contains(0x0A) {
                let n = read(c, &buf, buf.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                if data.count + n > maximumRequestBytes {
                    tooLarge = true
                    break
                }
                data.append(buf, count: n)
            }
            if !tooLarge, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "events" {
                subscribe(c)
                continue
            }
            var reply: String
            if tooLarge {
                reply = "error: request exceeds \(maximumRequestBytes) bytes"
            } else {
                let line = String(data: data, encoding: .utf8) ?? ""
                var result = IPCReply.text("")
                DispatchQueue.main.sync { result = self.handler(line) }
                switch result {
                case .text(let text): reply = text
                case .background(let work): reply = work()
                }
            }
            reply += "\n"
            Self.writeAll(Data(reply.utf8), to: c)
            close(c)
        }
    }

    @discardableResult
    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
    }

    // MARK: Events

    private func subscribe(_ c: Int32) {
        // A reader that stops reading gets dropped instead of stalling its queue forever.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var first: [String] = []
        DispatchQueue.main.sync { first = self.greeting() }
        lock.lock()
        subscriberCount += 1
        let sub = Subscriber(fd: c, number: subscriberCount)
        subscribers.append(sub)
        lock.unlock()
        send(first, to: sub)
    }

    /// Sends lines to every `events` subscriber. Called on main.
    func broadcast(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        let subs = subscribers
        lock.unlock()
        for sub in subs { send(lines, to: sub) }
    }

    private func send(_ lines: [String], to sub: Subscriber) {
        guard !lines.isEmpty else { return }
        lock.lock()
        sub.pending += 1
        let behind = sub.pending > Self.maximumPending
        lock.unlock()
        if behind {
            drop(sub)
            return
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        sub.queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            sub.pending -= 1
            let closed = sub.closed
            self.lock.unlock()
            if !closed, !Self.writeAll(data, to: sub.fd) { self.drop(sub) }
        }
    }

    private func drop(_ sub: Subscriber) {
        lock.lock()
        let wasOpen = !sub.closed
        sub.closed = true
        subscribers.removeAll { $0 === sub }
        lock.unlock()
        // Close on the subscriber's queue, after any write already running.
        if wasOpen { sub.queue.async { close(sub.fd) } }
    }
}
