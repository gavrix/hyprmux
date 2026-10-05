import Accelerate
import AndroidEmulatorBridge
import AppKit
import HyprmuxClientKit

/// A running Android Virtual Device, streamed from the emulator's local gRPC endpoint.
/// The emulator sends RGBA pixels, not a surface, so each frame is written once into a
/// subsurface buffer (swapping to BGRA on the way).
final class AndroidWindow: DeviceWindow {
    private static let maximumStreamWidth = 720
    private static let maximumStreamHeight = 1280

    let endpoint: AndroidEmulatorEndpoint
    private let client: AndroidEmulatorClient
    private let renderQueue = DispatchQueue(label: "dev.gavrix.hyprmux.mobile.android", qos: .userInteractive)
    private let lock = NSLock()
    /// The newest frame not yet drawn. Older ones are dropped.
    private var pendingFrame: AndroidEmulatorFrame?
    private var drawing = false
    /// The device's native size, from the first full-size frame. Touches use it.
    private var devicePixels = CGSize.zero
    private var streaming = false
    private var lastTouch = CGPoint.zero

    init(mobile: Mobile, endpoint: AndroidEmulatorEndpoint, restoreToken: String?, launch: HMLaunch?) throws {
        self.endpoint = endpoint
        client = try AndroidEmulatorClient(endpoint: endpoint)
        super.init(mobile: mobile, title: endpoint.name, restoreToken: restoreToken, launch: launch)
        deviceScreen.onBufferReleased = { [weak self] in self?.drawPending() }
    }

    override var barHeight: CGFloat { 30 }

    override var buttons: [Button] {
        [Button(symbol: "arrowtriangle.backward.fill", label: "Back") { [weak self] in self?.press(.back) },
         Button(symbol: "circle", label: "Home") { [weak self] in self?.press(.home) },
         Button(symbol: "square", label: "Recent apps") { [weak self] in self?.press(.appSwitch) }]
    }

    override func configured(_ c: HMConfigure) {
        super.configured(c)
        if !c.occluded, !streaming { startStreaming() }
    }

    override func occlusionChanged(_ occluded: Bool) {
        if occluded {
            if lastTouch != .zero { client.sendTouch(x: Int32(lastTouch.x), y: Int32(lastTouch.y), isDown: false) }
            streaming = false
            client.stopScreenshotStream()
        } else if !streaming {
            startStreaming()
        }
    }

    // MARK: Frames

    private func startStreaming() {
        guard !closed else { return }
        streaming = true
        lock.lock()
        let knowsSize = devicePixels != .zero
        lock.unlock()
        startStream(reduced: knowsSize)
    }

    /// The first frame comes at full size, for the device's size; then a reduced stream.
    private func startStream(reduced: Bool) {
        client.startScreenshotStream(
            maximumWidth: reduced ? Self.maximumStreamWidth : 0,
            maximumHeight: reduced ? Self.maximumStreamHeight : 0
        ) { [weak self] frame in
            self?.received(frame)
        } onFailure: { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed, self.streaming else { return }
                self.streaming = false
                self.message = "Android Emulator: \(error.localizedDescription)"
            }
        }
    }

    /// Any thread. Keeps only the newest frame.
    private func received(_ frame: AndroidEmulatorFrame) {
        lock.lock()
        let first = devicePixels == .zero
        if first { devicePixels = CGSize(width: frame.width, height: frame.height) }
        pendingFrame = frame
        lock.unlock()
        if first { startStream(reduced: true) }
        DispatchQueue.main.async { [weak self] in self?.drawPending() }
    }

    /// Main thread: write the newest frame into a free buffer, then present it.
    private func drawPending() {
        guard !closed, !drawing, streaming else { return }
        lock.lock()
        guard let frame = pendingFrame else {
            lock.unlock()
            return
        }
        lock.unlock()
        // Every buffer on screen: the next release draws.
        guard let buffer = deviceScreen.acquireBuffer(width: frame.width, height: frame.height) else { return }
        lock.lock()
        pendingFrame = nil
        lock.unlock()
        drawing = true
        renderQueue.async { [weak self] in
            Self.write(frame, into: buffer)
            DispatchQueue.main.async {
                guard let self else { return }
                self.drawing = false
                guard !self.closed else { return }
                if self.message != nil { self.message = nil }
                self.screenPixels = CGSize(width: frame.width, height: frame.height)
                self.deviceScreen.present(buffer)
                self.drawPending()
            }
        }
    }

    /// RGBA8888 to the buffer's BGRA, row by row: one pass over the pixels.
    private static func write(_ frame: AndroidEmulatorFrame, into buffer: HMBuffer) {
        IOSurfaceLock(buffer.surface, [], nil)
        defer { IOSurfaceUnlock(buffer.surface, [], nil) }
        let base = IOSurfaceGetBaseAddress(buffer.surface)
        frame.rgba.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(frame.height),
                                       width: vImagePixelCount(frame.width), rowBytes: frame.width * 4)
            var destination = vImage_Buffer(data: base, height: vImagePixelCount(buffer.height),
                                            width: vImagePixelCount(buffer.width), rowBytes: buffer.bytesPerRow)
            let rgbaToBGRA: [UInt8] = [2, 1, 0, 3]
            vImagePermuteChannels_ARGB8888(&source, &destination, rgbaToBGRA, vImage_Flags(kvImageNoFlags))
        }
    }

    // MARK: Input

    private func devicePoint(_ ratio: CGPoint) -> CGPoint? {
        lock.lock()
        var input = devicePixels
        lock.unlock()
        guard input != .zero, screenPixels != .zero else { return nil }
        // The stream may be rotated relative to the size the first frame reported.
        if (screenPixels.width > screenPixels.height) != (input.width > input.height) {
            input = CGSize(width: input.height, height: input.width)
        }
        return CGPoint(x: ratio.x * (max(1, input.width) - 1), y: ratio.y * (max(1, input.height) - 1))
    }

    override func touch(_ ratio: CGPoint, phase: TouchPhase) {
        guard let p = devicePoint(ratio) else { return }
        lastTouch = phase == .up ? .zero : p
        client.sendTouch(x: Int32(p.x.rounded()), y: Int32(p.y.rounded()), isDown: phase != .up) { [weak self] error in
            DispatchQueue.main.async { self?.inputFailed(error) }
        }
    }

    override func key(_ e: HMKeyEvent) {
        guard !(e.down && e.isRepeat) else { return }
        sendKey(e.keyCode, down: e.down)
    }

    override func modifier(_ flag: UInt64, down: Bool) {
        let code: UInt16
        switch NSEvent.ModifierFlags(rawValue: UInt(flag)) {
        case .shift: code = 56
        case .control: code = 59
        case .option: code = 58
        case .command: code = 55
        default: code = 57  // caps lock
        }
        sendKey(code, down: down)
    }

    private func sendKey(_ code: UInt16, down: Bool) {
        client.sendKey(macKeyCode: code, isDown: down) { [weak self] error in
            DispatchQueue.main.async { self?.inputFailed(error) }
        }
    }

    private func press(_ button: AndroidEmulatorHardwareButton) {
        client.pressHardwareButton(button) { [weak self] error in
            DispatchQueue.main.async { self?.inputFailed(error) }
        }
    }

    private func inputFailed(_ error: Error) {
        guard !closed else { return }
        message = "Android Emulator: \(error.localizedDescription)"
    }

    override func stop() {
        streaming = false
        if lastTouch != .zero { client.sendTouch(x: Int32(lastTouch.x), y: Int32(lastTouch.y), isDown: false) }
        client.close()
    }
}
