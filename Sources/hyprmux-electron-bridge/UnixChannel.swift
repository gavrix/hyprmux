// A unix-socket server with the hook's framing:
// [u32 LE json length][json][u32 LE payload length][payload].
import Foundation

final class UnixChannel {
    final class Conn {
        let fd: Int32
        var onMessage: (([String: Any], Data?) -> Void)?
        var onClose: (() -> Void)?
        private var pending = Data()
        /// One read buffer per connection. Allocating and zeroing a fresh one per read
        /// cost more than the frames themselves: sockets deliver a 13 MB frame in many reads.
        private var readBuffer = [UInt8](repeating: 0, count: 1 << 20)
        private var source: DispatchSourceRead?
        private let writeLock = NSLock()

        init(fd: Int32) { self.fd = fd }

        func start() {
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
            s.setEventHandler { [weak self] in self?.readSome() }
            s.setCancelHandler { Darwin.close(self.fd) }
            source = s
            s.resume()
        }

        private func readSome() {
            let n = readBuffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { source?.cancel(); onClose?(); return }
            readBuffer.withUnsafeBytes { pending.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n) }
            while true {
                // Data keeps its original indices after removeFirst, so index from startIndex
                // and rebase the buffer after each frame.
                guard pending.count >= 8 else { return }
                let s = pending.startIndex
                let (jlen, blen) = pending.withUnsafeBytes { raw in
                    (Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))),
                     Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))))
                }
                let total = 8 + jlen + blen
                guard pending.count >= total else { return }
                let jsonData = pending.subdata(in: s + 8..<s + 8 + jlen)
                let payload = blen > 0 ? pending.subdata(in: s + 8 + jlen..<s + total) : nil
                pending = pending.count > total ? pending.subdata(in: s + total..<pending.endIndex) : Data()
                guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                onMessage?(json, payload)
            }
        }

        func send(_ json: [String: Any], payload: Data? = nil) {
            guard let j = try? JSONSerialization.data(withJSONObject: json) else { return }
            var frame = Data(capacity: 8 + j.count + (payload?.count ?? 0))
            var jlen = UInt32(j.count).littleEndian
            var blen = UInt32(payload?.count ?? 0).littleEndian
            withUnsafeBytes(of: &jlen) { frame.append(contentsOf: $0) }
            withUnsafeBytes(of: &blen) { frame.append(contentsOf: $0) }
            frame.append(j)
            if let payload { frame.append(payload) }
            writeLock.lock(); defer { writeLock.unlock() }
            frame.withUnsafeBytes { ptr in
                var sent = 0
                while sent < frame.count {
                    let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: sent), frame.count - sent)
                    if n <= 0 { return }
                    sent += n
                }
            }
        }

        func close() { source?.cancel() }
    }

    let path: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    var onAccept: ((Conn) -> Void)?

    init(path: String) { self.path = path }

    func start() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPath else { throw POSIXError(.ENAMETOOLONG) }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), $0, maxPath - 1) }
        }
        var bound = addr
        let rc = withUnsafePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(listenFD, 8) == 0 else { throw POSIXError(.EIO) }
        let s = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .global(qos: .userInteractive))
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let fd = accept(self.listenFD, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            // Frames are megabytes each; the default socket buffers are a few KB.
            var size: Int32 = 8 << 20
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            let c = Conn(fd: fd)
            self.onAccept?(c)
            c.start()
        }
        s.setCancelHandler { [self] in Darwin.close(self.listenFD); unlink(self.path) }
        source = s
        s.resume()
    }

    func close() { source?.cancel() }
}
