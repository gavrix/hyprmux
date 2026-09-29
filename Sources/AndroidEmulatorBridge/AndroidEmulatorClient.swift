import Foundation
import GRPC
import NIO
import NIOPosix
import SwiftProtobuf

public enum AndroidEmulatorFrameTransport: String, Sendable {
    case grpc
    case mmap
}

public enum AndroidEmulatorHardwareButton: Sendable {
    case back
    case home
    case appSwitch

    var key: String {
        switch self {
        case .back: return "GoBack"
        case .home: return "GoHome"
        case .appSwitch: return "AppSwitch"
        }
    }
}

public struct AndroidEmulatorFrame: Sendable {
    public let rgba: Data
    public let width: Int
    public let height: Int
    public let sequence: UInt32
    public let timestampMicroseconds: UInt64
    public let transport: AndroidEmulatorFrameTransport
}

public enum AndroidEmulatorBridgeError: LocalizedError {
    case closed
    case rpc(String, String)

    public var errorDescription: String? {
        switch self {
        case .closed: return "The Android Emulator connection is closed."
        case .rpc(let method, let message): return "Android Emulator \(method) failed: \(message)"
        }
    }
}

/// A small client for the Android Emulator RPCs used by Hyprmux.
/// Authentication metadata is created from discovery and never exposed publicly.
public final class AndroidEmulatorClient {
    private static let maximumFrameBytes = 128 * 1024 * 1024

    private let group: MultiThreadedEventLoopGroup
    private let channel: GRPCChannel
    private let client: Android_Emulation_Control_EmulatorControllerNIOClient
    private let inputCall: ClientStreamingCall<Android_Emulation_Control_InputEvent, Google_Protobuf_Empty>
    private let supportsSharedMemoryScreenshots: Bool
    private let lock = NSLock()
    private var screenshotCall: ServerStreamingCall<Android_Emulation_Control_ImageFormat, Android_Emulation_Control_Image>?
    private var inputFailureHandler: ((Error) -> Void)?
    private var streamGeneration: UInt64 = 0
    private var closed = false

    public init(endpoint: AndroidEmulatorEndpoint) throws {
        supportsSharedMemoryScreenshots = endpoint.supportsSharedMemoryScreenshots
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let grpcChannel: GRPCChannel
        do {
            grpcChannel = try GRPCChannelPool.with(
                target: .host(endpoint.host, port: endpoint.port),
                transportSecurity: .plaintext,
                eventLoopGroup: eventLoopGroup
            ) { configuration in
                // Native RGBA frames exceed gRPC's default message and flow-control windows.
                configuration.maximumReceiveMessageLength = Self.maximumFrameBytes
                configuration.http2.targetWindowSize = 32 * 1024 * 1024
            }
        } catch {
            try? eventLoopGroup.syncShutdownGracefully()
            throw error
        }
        group = eventLoopGroup
        channel = grpcChannel
        var options = CallOptions()
        if let token = endpoint.bearerToken {
            options.customMetadata.add(name: "authorization", value: "Bearer \(token)")
        }
        let grpcClient = Android_Emulation_Control_EmulatorControllerNIOClient(
            channel: channel,
            defaultCallOptions: options
        )
        client = grpcClient
        inputCall = grpcClient.streamInputEvent()
        inputCall.status.whenSuccess { [weak self] status in
            guard status.code != .ok else { return }
            self?.reportInputFailure(AndroidEmulatorBridgeError.rpc(
                "streamInputEvent",
                status.message ?? String(describing: status.code)
            ))
        }
    }

    /// Starts a raw RGBA stream within optional dimensions. Starting again replaces the old stream.
    public func startScreenshotStream(
        maximumWidth: Int = 0,
        maximumHeight: Int = 0,
        onFrame: @escaping (AndroidEmulatorFrame) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        startScreenshotStream(
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            allowSharedMemory: true,
            onFrame: onFrame,
            onFailure: onFailure
        )
    }

    private func startScreenshotStream(
        maximumWidth: Int,
        maximumHeight: Int,
        allowSharedMemory: Bool,
        onFrame: @escaping (AndroidEmulatorFrame) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        let generation: UInt64
        let previous: ServerStreamingCall<Android_Emulation_Control_ImageFormat, Android_Emulation_Control_Image>?
        lock.lock()
        if closed {
            lock.unlock()
            onFailure(AndroidEmulatorBridgeError.closed)
            return
        }
        streamGeneration &+= 1
        generation = streamGeneration
        previous = screenshotCall
        screenshotCall = nil
        lock.unlock()
        previous?.cancel(promise: nil)

        var request = Android_Emulation_Control_ImageFormat()
        request.format = .rgba8888
        request.width = UInt32(clamping: maximumWidth)
        request.height = UInt32(clamping: maximumHeight)

        let mapping: AndroidEmulatorMappedFile?
        if allowSharedMemory, supportsSharedMemoryScreenshots,
           let capacity = Self.rgbaByteCount(width: maximumWidth, height: maximumHeight) {
            mapping = try? AndroidEmulatorMappedFile(capacity: capacity)
            if let mapping {
                request.transport.channel = .mmap
                request.transport.handle = mapping.url.absoluteString
            }
        } else {
            mapping = nil
        }

        let call = client.streamScreenshot(request) { [weak self, mapping] image in
            guard let self, self.isCurrentStream(generation) else { return }
            let dimensions = Self.dimensions(of: image)
            guard let byteCount = Self.rgbaByteCount(
                width: dimensions.width,
                height: dimensions.height
            ) else { return }

            let pixels: Data
            let transport: AndroidEmulatorFrameTransport
            if !image.image.isEmpty, image.image.count == byteCount {
                pixels = image.image
                transport = .grpc
            } else if let snapshot = mapping?.snapshot(byteCount: byteCount) {
                pixels = snapshot
                transport = .mmap
            } else {
                return
            }

            onFrame(AndroidEmulatorFrame(
                rgba: pixels,
                width: dimensions.width,
                height: dimensions.height,
                sequence: image.seq,
                timestampMicroseconds: image.timestampUs,
                transport: transport
            ))
        }

        call.status.whenSuccess { [weak self, mapping] status in
            // Keep the mapping valid until the emulator acknowledges cancellation.
            _ = mapping
            guard let self else { return }
            self.lock.lock()
            let current = !self.closed && generation == self.streamGeneration
            self.lock.unlock()
            guard current, status.code != .ok else { return }
            if mapping != nil {
                self.startScreenshotStream(
                    maximumWidth: maximumWidth,
                    maximumHeight: maximumHeight,
                    allowSharedMemory: false,
                    onFrame: onFrame,
                    onFailure: onFailure
                )
            } else {
                onFailure(AndroidEmulatorBridgeError.rpc(
                    "streamScreenshot",
                    status.message ?? String(describing: status.code)
                ))
            }
        }

        lock.lock()
        let keep = !closed && generation == streamGeneration
        if keep { screenshotCall = call }
        lock.unlock()
        if !keep { call.cancel(promise: nil) }
    }

    public func stopScreenshotStream() {
        lock.lock()
        streamGeneration &+= 1
        let call = screenshotCall
        screenshotCall = nil
        lock.unlock()
        call?.cancel(promise: nil)
    }

    /// Sends one contact update. Pressure zero ends the contact.
    public func sendTouch(x: Int32, y: Int32, isDown: Bool, onFailure: ((Error) -> Void)? = nil) {
        guard isOpen else {
            onFailure?(AndroidEmulatorBridgeError.closed)
            return
        }
        var touch = Android_Emulation_Control_Touch()
        touch.x = max(0, x)
        touch.y = max(0, y)
        touch.identifier = 0
        touch.pressure = isDown ? 1 : 0
        touch.expiration = isDown ? .neverExpire : .unspecified
        var touchEvent = Android_Emulation_Control_TouchEvent()
        touchEvent.touches = [touch]
        var input = Android_Emulation_Control_InputEvent()
        input.touchEvent = touchEvent
        sendInput(input, onFailure: onFailure)
    }

    /// Presses one Android navigation button using the emulator's W3C key names.
    public func pressHardwareButton(
        _ button: AndroidEmulatorHardwareButton,
        onFailure: ((Error) -> Void)? = nil
    ) {
        guard isOpen else {
            onFailure?(AndroidEmulatorBridgeError.closed)
            return
        }
        var keyEvent = Android_Emulation_Control_KeyboardEvent()
        keyEvent.eventType = .keypress
        keyEvent.key = button.key
        var input = Android_Emulation_Control_InputEvent()
        input.keyEvent = keyEvent
        sendInput(input, onFailure: onFailure)
    }

    /// Sends a physical macOS key code. The emulator translates its `Mac` code type to evdev.
    public func sendKey(macKeyCode: UInt16, isDown: Bool, onFailure: ((Error) -> Void)? = nil) {
        guard isOpen else {
            onFailure?(AndroidEmulatorBridgeError.closed)
            return
        }
        var keyEvent = Android_Emulation_Control_KeyboardEvent()
        keyEvent.codeType = .mac
        keyEvent.eventType = isDown ? .keydown : .keyup
        keyEvent.keyCode = Int32(macKeyCode)
        var input = Android_Emulation_Control_InputEvent()
        input.keyEvent = keyEvent
        sendInput(input, onFailure: onFailure)
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        streamGeneration &+= 1
        let call = screenshotCall
        screenshotCall = nil
        inputFailureHandler = nil
        lock.unlock()

        inputCall.sendEnd(promise: nil)
        call?.cancel(promise: nil)
        channel.close().whenComplete { [group] _ in
            group.shutdownGracefully { _ in }
        }
    }

    deinit { close() }

    private var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    private func sendInput(
        _ input: Android_Emulation_Control_InputEvent,
        onFailure: ((Error) -> Void)?
    ) {
        lock.lock()
        if let onFailure { inputFailureHandler = onFailure }
        let open = !closed
        lock.unlock()
        guard open else {
            onFailure?(AndroidEmulatorBridgeError.closed)
            return
        }
        inputCall.sendMessage(input).whenFailure { error in
            onFailure?(AndroidEmulatorBridgeError.rpc("streamInputEvent", String(describing: error)))
        }
    }

    private func reportInputFailure(_ error: Error) {
        lock.lock()
        let handler = closed ? nil : inputFailureHandler
        lock.unlock()
        handler?(error)
    }

    private func isCurrentStream(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && generation == streamGeneration
    }

    static func rgbaByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelsOverflow, !bytesOverflow, bytes <= maximumFrameBytes else { return nil }
        return bytes
    }

    private static func dimensions(of image: Android_Emulation_Control_Image) -> (width: Int, height: Int) {
        let width = image.hasFormat && image.format.width > 0 ? image.format.width : image.width
        let height = image.hasFormat && image.format.height > 0 ? image.format.height : image.height
        return (Int(width), Int(height))
    }
}
