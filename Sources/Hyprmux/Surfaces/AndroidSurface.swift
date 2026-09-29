import AndroidEmulatorBridge
import AppKit
import HyprmuxCore

/// A running Android Virtual Device streamed from the emulator's local gRPC endpoint.
final class AndroidSurface: FlippedView, Surface {
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let maximumStreamWidth = 720
    private static let maximumStreamHeight = 1280

    let clientID: ClientID
    let endpoint: AndroidEmulatorEndpoint
    var onClose: ((AndroidSurface) -> Void)?
    var onError: ((String) -> Void)?

    private let client: AndroidEmulatorClient
    private let screen = PassthroughView()
    private let bar = NSView()
    private let backButton = BarButton(symbol: "arrowtriangle.backward.fill", label: "Back")
    private let homeButton = BarButton(symbol: "circle", label: "Home")
    private let appSwitchButton = BarButton(symbol: "square", label: "Recent apps")
    private let barHeight: CGFloat = 30
    private let renderQueue = DispatchQueue(label: "dev.hyprmux.android-rgba", qos: .userInteractive)
    private let frameLock = NSLock()
    private var pendingFrame: AndroidEmulatorFrame?
    private var processingFrame = false
    private var displayPixels = CGSize.zero
    private var devicePixels = CGSize.zero
    private var displayedSequence: UInt32 = 0
    private var frameTransport: AndroidEmulatorFrameTransport = .grpc
    private var frameLatencyMilliseconds = 0
    private var frameRate = 0.0
    private var lastFrameTime: CFTimeInterval?
    private var touching = false
    private var lastTouch = CGPoint.zero
    private var streaming = false
    private var closed = false
    private var reportedError = false
    private var lastError: String?
    private var touchesSent = 0
    private var keysSent = 0
    private var hardwareButtonsSent = 0

    init(id: ClientID, endpoint: AndroidEmulatorEndpoint) throws {
        clientID = id
        self.endpoint = endpoint
        client = try AndroidEmulatorClient(endpoint: endpoint)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        screen.wantsLayer = true
        screen.layer?.contentsGravity = .resizeAspect
        screen.layer?.magnificationFilter = .linear
        screen.layer?.minificationFilter = .trilinear
        addSubview(screen)

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        addSubview(bar)
        for (button, action) in [
            (backButton, #selector(backClicked)),
            (homeButton, #selector(homeClicked)),
            (appSwitchButton, #selector(appSwitchClicked)),
        ] {
            button.target = self
            button.action = action
            bar.addSubview(button)
        }
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    private func layoutContent() {
        let height = min(barHeight, bounds.height)
        screen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height)
        bar.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)

        let buttonSize: CGFloat = 22
        let spacing: CGFloat = 42
        let buttons = [backButton, homeButton, appSwitchButton]
        let totalWidth = CGFloat(buttons.count) * buttonSize + CGFloat(buttons.count - 1) * spacing
        var x = (bounds.width - totalWidth) / 2
        for button in buttons {
            button.frame = CGRect(x: x, y: (height - buttonSize) / 2, width: buttonSize, height: buttonSize)
            x += buttonSize + spacing
        }
    }

    @objc private func backClicked() { press(.back) }
    @objc private func homeClicked() { press(.home) }
    @objc private func appSwitchClicked() { press(.appSwitch) }

    // MARK: Surface

    var view: NSView { self }
    var focusTarget: NSView { self }
    var title: String { endpoint.name }
    var kind: String { "android" }
    var backdropColor: NSColor { .black }
    var info: [String: Any] {
        var result: [String: Any] = ["avd": endpoint.avdID, "device": endpoint.name]
        if displayPixels.width > 0, displayPixels.height > 0 {
            result["pixels"] = [Int(displayPixels.width), Int(displayPixels.height)]
            result["frame"] = Int(displayedSequence)
            result["fps"] = Int(frameRate.rounded())
            result["latencyMs"] = frameLatencyMilliseconds
            result["transport"] = "\(frameTransport.rawValue.uppercased()) RGBA8888"
        }
        result["touchesSent"] = touchesSent
        result["keysSent"] = keysSent
        result["hardwareButtonsSent"] = hardwareButtonsSent
        if let lastError { result["inputError"] = lastError }
        return result
    }

    func setOccluded(_ occluded: Bool) {
        guard !closed else { return }
        if occluded {
            if touching { sendTouch(at: lastTouch, down: false) }
            touching = false
            streaming = false
            client.stopScreenshotStream()
        } else if !streaming {
            startStreaming()
        }
    }

    func requestClose() {
        guard !closed else { return }
        closed = true
        if touching { sendTouch(at: lastTouch, down: false) }
        touching = false
        streaming = false
        client.close()
        onClose?(self)
    }

    func destroy() {
        guard !closed else { return }
        closed = true
        client.close()
    }

    // MARK: Display

    private func startStreaming() {
        streaming = true
        lastFrameTime = nil
        frameRate = 0
        frameLock.lock()
        let knowsDeviceSize = devicePixels.width > 0 && devicePixels.height > 0
        frameLock.unlock()
        startScreenshotStream(reduced: knowsDeviceSize)
    }

    private func startScreenshotStream(reduced: Bool) {
        client.startScreenshotStream(
            maximumWidth: reduced ? Self.maximumStreamWidth : 0,
            maximumHeight: reduced ? Self.maximumStreamHeight : 0
        ) { [weak self] frame in
            self?.enqueue(frame)
        } onFailure: { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.streaming = false
                self.report(error)
            }
        }
    }

    /// Keep only the newest raw frame while Core Animation presents the current one.
    private func enqueue(_ frame: AndroidEmulatorFrame) {
        frameLock.lock()
        let needsReducedStream = devicePixels == .zero
        if needsReducedStream {
            devicePixels = CGSize(width: frame.width, height: frame.height)
        }
        pendingFrame = frame
        let shouldStart = !processingFrame
        if shouldStart { processingFrame = true }
        frameLock.unlock()

        if needsReducedStream { startScreenshotStream(reduced: true) }
        guard shouldStart else { return }
        renderQueue.async { [weak self] in self?.renderNextFrame() }
    }

    private func renderNextFrame() {
        frameLock.lock()
        guard let frame = pendingFrame else {
            processingFrame = false
            frameLock.unlock()
            return
        }
        pendingFrame = nil
        frameLock.unlock()

        let bytesPerRow = frame.width * 4
        guard let provider = CGDataProvider(data: frame.rgba as CFData),
              let image = CGImage(
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: Self.colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            renderQueue.async { [weak self] in self?.renderNextFrame() }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.closed, self.streaming {
                self.displayPixels = CGSize(width: frame.width, height: frame.height)
                self.recordFrame(frame)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.screen.layer?.contents = image
                CATransaction.commit()
            }
            self.renderQueue.async { [weak self] in self?.renderNextFrame() }
        }
    }

    private func recordFrame(_ frame: AndroidEmulatorFrame) {
        let now = CACurrentMediaTime()
        if let lastFrameTime {
            let instantaneous = 1 / max(now - lastFrameTime, 0.001)
            frameRate = frameRate == 0 ? instantaneous : frameRate * 0.9 + instantaneous * 0.1
        }
        lastFrameTime = now
        displayedSequence = frame.sequence
        frameTransport = frame.transport
        let nowMicroseconds = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        if frame.timestampMicroseconds > 0, nowMicroseconds >= frame.timestampMicroseconds {
            frameLatencyMilliseconds = Int((nowMicroseconds - frame.timestampMicroseconds) / 1_000)
        }
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The aspect-fit device screen inside the tile, in top-left coordinates.
    private var screenRect: CGRect {
        let area = screen.frame
        guard displayPixels.width > 0, displayPixels.height > 0 else { return area }
        let scale = min(area.width / displayPixels.width, area.height / displayPixels.height)
        let size = CGSize(width: displayPixels.width * scale, height: displayPixels.height * scale)
        return CGRect(
            x: area.minX + (area.width - size.width) / 2,
            y: area.minY + (area.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func devicePoint(_ event: NSEvent, clamp: Bool) -> CGPoint? {
        guard displayPixels.width > 0, displayPixels.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let rect = screenRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        var x = (point.x - rect.minX) / rect.width
        var y = (point.y - rect.minY) / rect.height
        if clamp {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        } else if !(0...1).contains(x) || !(0...1).contains(y) {
            return nil
        }
        frameLock.lock()
        var inputPixels = devicePixels
        frameLock.unlock()
        if (displayPixels.width > displayPixels.height) != (inputPixels.width > inputPixels.height) {
            inputPixels = CGSize(width: inputPixels.height, height: inputPixels.width)
        }
        let width = max(1, inputPixels.width)
        let height = max(1, inputPixels.height)
        return CGPoint(x: x * (width - 1), y: y * (height - 1))
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = devicePoint(event, clamp: false) else { return }
        touching = true
        lastTouch = point
        sendTouch(at: point, down: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let point = devicePoint(event, clamp: true) else { return }
        lastTouch = point
        sendTouch(at: point, down: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching else { return }
        touching = false
        let point = devicePoint(event, clamp: true) ?? lastTouch
        lastTouch = point
        sendTouch(at: point, down: false)
    }

    private func sendTouch(at point: CGPoint, down: Bool) {
        touchesSent += 1
        client.sendTouch(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), isDown: down) { [weak self] error in
            DispatchQueue.main.async { self?.report(error) }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        sendKey(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 54, 55: flag = .command
        case 56, 60: flag = .shift
        case 58, 61: flag = .option
        case 59, 62: flag = .control
        case 57: flag = .capsLock
        default: return
        }
        sendKey(event.keyCode, down: event.modifierFlags.contains(flag))
    }

    private func sendKey(_ code: UInt16, down: Bool) {
        keysSent += 1
        client.sendKey(macKeyCode: code, isDown: down) { [weak self] error in
            DispatchQueue.main.async { self?.report(error) }
        }
    }

    private func press(_ button: AndroidEmulatorHardwareButton) {
        guard !closed else { return }
        hardwareButtonsSent += 1
        client.pressHardwareButton(button) { [weak self] error in
            DispatchQueue.main.async { self?.report(error) }
        }
    }

    private func report(_ error: Error) {
        guard !closed else { return }
        lastError = error.localizedDescription
        guard !reportedError else { return }
        reportedError = true
        onError?(error.localizedDescription)
    }
}
