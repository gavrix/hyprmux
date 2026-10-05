// hyprmux-mobile: Mobile.hmapp's program (Resources/apps/Mobile.hmapp). It shows booted
// iOS Simulators and running Android Emulators as Hyprmux windows, all from one process.
// Hyprmux starts it; it answers every launch (docs/CLIENT_PROTOCOL.md, Launches).
//
//   hyprmux-mobile          run as Hyprmux's client
//   hyprmux-mobile list     print the devices it would offer, as JSON
//   hyprmux-mobile info UDID   an iOS Simulator's framebuffer: size and pixel format
import Foundation
import HyprmuxClientKit
import IOSurface
import SimulatorBridge

/// Logs to stderr with write(2); Hyprmux keeps the last line when Mobile fails.
func stderr(_ s: String) {
    let line = s + "\n"
    line.utf8CString.withUnsafeBufferPointer { p in _ = write(STDERR_FILENO, p.baseAddress, p.count - 1) }
}

if CommandLine.arguments.dropFirst().first == "list" {
    let (devices, problems) = Devices.running()
    let list = devices.map { ["id": $0.id, "title": $0.name, "detail": $0.detail] }
    let out: [String: Any] = ["devices": list, "problems": problems]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "info" {
    do {
        let display = try HMSimDisplay(query: CommandLine.arguments[2])
        // The framebuffer arrives with the first frame callback.
        let deadline = Date().addingTimeInterval(3)
        while display.surface == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let s = display.surface else { stderr("no framebuffer"); exit(1) }
        let f = IOSurfaceGetPixelFormat(s)
        let code = String(bytes: [24, 16, 8, 0].map { UInt8((f >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
        print("\(display.name): \(IOSurfaceGetWidth(s))×\(IOSurfaceGetHeight(s)) px, format '\(code)', \(IOSurfaceGetBytesPerElement(s)) bytes per pixel")
        display.stop()
        exit(0)
    } catch {
        stderr("hyprmux-mobile: \(error.localizedDescription)")
        exit(1)
    }
}

let client = HMClient(appID: "dev.gavrix.hyprmux.mobile", name: "Mobile")
let mobile = Mobile(client: client)
client.onDisconnect = { reason in
    stderr("hyprmux-mobile: \(reason)")
    exit(0)
}
do { try client.connect() } catch {
    stderr("hyprmux-mobile: \(error)")
    exit(1)
}
// A launch arrives right after the handshake. Without one (it was cancelled), quit.
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { mobile.quitIfIdle() }
RunLoop.main.run()
