import Foundation
import HypermuxCore

// hyprctl-style client for the hypermux control socket.
//   hypermuxctl dispatch workspace 2
//   hypermuxctl clients

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty, args[0] != "-h", args[0] != "--help" else {
    print("""
    usage: hypermuxctl <command> [args]
      dispatch <dispatcher> [args]   run a dispatcher (same names as bind lines)
      clients | workspaces | activewindow | version
      reload                         reload the config
      sendtext <text>                type text into the focused terminal (\\n = enter)
      sendkey <MODS>, <key>          inject a key press, e.g. 'SUPER, Return'
      senddrag <MODS>, <button>, <x1 y1>, <x2 y2>   inject a mouse drag (272 left, 273 right)
    """)
    exit(args.isEmpty ? 1 : 0)
}

let path = IPCPath.default
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { perror("socket"); exit(1) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    path.utf8CString.withUnsafeBytes { src in memcpy(buf.baseAddress!, src.baseAddress!, min(buf.count - 1, src.count)) }
}
let ok = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard ok == 0 else {
    FileHandle.standardError.write("hypermuxctl: cannot connect to \(path) (is Hypermux running?)\n".data(using: .utf8)!)
    exit(1)
}
let line = args.joined(separator: " ") + "\n"
_ = line.withCString { write(fd, $0, strlen($0)) }
shutdown(fd, SHUT_WR)
var out = Data()
var buf = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    out.append(buf, count: n)
}
close(fd)
let reply = String(data: out, encoding: .utf8) ?? ""
print(reply, terminator: reply.hasSuffix("\n") ? "" : "\n")
exit(reply.hasPrefix("error") ? 1 : 0)
