import Foundation
import HyprmuxCore

/// Serves the control socket. Each connection sends one line and gets one reply.
final class IPCServer {
    let path: String
    private var fd: Int32 = -1
    private let handler: (String) -> String

    init?(path: String, handler: @escaping (String) -> String) {
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
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while !data.contains(0x0A) {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            let line = String(data: data, encoding: .utf8) ?? ""
            var reply = ""
            DispatchQueue.main.sync { reply = self.handler(line) }
            reply += "\n"
            _ = reply.withCString { write(c, $0, strlen($0)) }
            close(c)
        }
    }
}
