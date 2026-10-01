// Swift client kit for the Hyprmux client protocol (docs/CLIENT_PROTOCOL.md).
// Connects through the broker, creates toplevels, manages an IOSurface swapchain,
// and delivers configure, frame, and input events on one queue.
//
// A C ABI for C++ and Rust clients comes later; this kit is the reference for it.
import Foundation
@_exported import HyprmuxClientProtocol
import IOSurface
import XPC

public enum HMClientError: Error, CustomStringConvertible {
    case brokerUnavailable
    case notRunning(instance: String)
    case handshake(String)

    public var description: String {
        switch self {
        case .brokerUnavailable: "hyprmux-broker isn't loaded (scripts/dev-broker.sh load)"
        case .notRunning(let i): "no Hyprmux instance '\(i)' is running"
        case .handshake(let m): "handshake failed: \(m)"
        }
    }
}

public struct HMConfigure {
    /// Size in points. Draw `width × scale` by `height × scale` pixels.
    public var width: Double
    public var height: Double
    public var scale: Double
    public var states: Set<String>
    public var serial: UInt64
    public var pixelWidth: Int { Int((width * scale).rounded()) }
    public var pixelHeight: Int { Int((height * scale).rounded()) }
    public var activated: Bool { states.contains(HMToplevelState.activated) }
    public var occluded: Bool { states.contains(HMToplevelState.occluded) }
}

public enum HMPointerEvent {
    case enter(x: Double, y: Double)
    case leave
    case motion(x: Double, y: Double, buttons: UInt64, modifiers: UInt64)
    case button(x: Double, y: Double, button: Int, down: Bool, clickCount: Int, modifiers: UInt64)
    /// `dx`/`dy` are AppKit's `scrollingDelta`: points when `precise` (trackpads),
    /// lines otherwise (notched wheels). `ticksX`/`ticksY` count raw wheel notches,
    /// without acceleration; zero for precise devices.
    case scroll(x: Double, y: Double, dx: Double, dy: Double, precise: Bool, phase: UInt64, momentumPhase: UInt64,
                ticksX: Double, ticksY: Double)
}

/// One atomic text-input update, delivered at `text_input.done` (Wayland's
/// text-input-v3 order): delete around the caret, insert the commit, then show the
/// preedit. Offsets are UTF-16 code units.
public struct HMTextInputUpdate {
    public var deleteBefore = 0
    public var deleteAfter = 0
    public var commit = ""
    /// The composition in progress; empty when none.
    public var preedit = ""
    public var preeditCursor = 0..<0
    public var serial: UInt64 = 0
}

public struct HMKeyEvent {
    public var keyCode: UInt16
    public var down: Bool
    public var isRepeat: Bool
    public var characters: String
    public var charactersIgnoringModifiers: String
    /// AppKit's device-independent `NSEvent.ModifierFlags` raw value.
    public var modifiers: UInt64
}

/// One swapchain image.
public final class HMBuffer {
    public let surface: IOSurfaceRef
    public let id: UInt64
    public internal(set) var busy = false
    public var width: Int { IOSurfaceGetWidth(surface) }
    public var height: Int { IOSurfaceGetHeight(surface) }
    public var bytesPerRow: Int { IOSurfaceGetBytesPerRow(surface) }
    init(surface: IOSurfaceRef, id: UInt64) { self.surface = surface; self.id = id }
}

public final class HMClient {
    public let appID: String
    public let name: String
    public let instance: String
    public var onDisconnect: ((String) -> Void)?
    let queue: DispatchQueue
    private var connection: xpc_connection_t?
    private var nextID: UInt64 = 1
    fileprivate var toplevelsBySurface: [UInt64: HMToplevel] = [:]
    fileprivate var toplevels: [UInt64: HMToplevel] = [:]
    fileprivate var buffers: [UInt64: HMBuffer] = [:]
    fileprivate var frameCallbacks: [UInt64: (Double) -> Void] = [:]
    fileprivate var dialogReplies: [UInt64: ([String: Any]) -> Void] = [:]
    fileprivate var menuReplies: [UInt64: (String?) -> Void] = [:]

    public init(appID: String, name: String, instance: String = HMProtocol.currentInstance, queue: DispatchQueue = .main) {
        self.appID = appID
        self.name = name
        self.instance = instance
        self.queue = queue
    }

    /// Looks up the compositor and says hello. Blocks briefly.
    public func connect() throws {
        let broker = xpc_connection_create_mach_service(HMProtocol.lookupService, nil, 0)
        xpc_connection_set_event_handler(broker) { _ in }
        xpc_connection_resume(broker)
        defer { xpc_connection_cancel(broker) }
        let found = xpc_connection_send_message_with_reply_sync(broker, xpcMessage(HMOp.lookup, ["instance": instance]))
        guard found.isDictionary else { throw HMClientError.brokerUnavailable }
        guard found.string("status") == "ok", let endpoint = found.value("endpoint") else {
            throw HMClientError.notRunning(instance: instance)
        }

        let c = xpc_connection_create_from_endpoint(endpoint as xpc_endpoint_t)
        xpc_connection_set_target_queue(c, queue)
        xpc_connection_set_event_handler(c) { [weak self] event in
            guard let self else { return }
            if event.isError {
                let reason = event === XPC_ERROR_CONNECTION_INVALID ? "Hyprmux went away" : "connection error"
                self.connection = nil
                self.onDisconnect?(reason)
                return
            }
            if event.isDictionary { self.handle(event) }
        }
        xpc_connection_resume(c)
        var hello: [String: Any] = ["version": HMProtocol.version, "app_id": appID, "name": name]
        if let token = ProcessInfo.processInfo.environment[HMProtocol.launchTokenVariable], !token.isEmpty {
            hello["launch_token"] = token
        }
        let welcome = xpc_connection_send_message_with_reply_sync(c, xpcMessage(HMOp.hello, hello))
        guard welcome.isDictionary, welcome.op == "welcome" else {
            throw HMClientError.handshake(welcome.isDictionary ? (welcome.string("message") ?? "rejected") : "no reply")
        }
        connection = c
    }

    /// A new tile. Wait for its first `onConfigure` before drawing. A `restoreToken`
    /// lets a restored session put this toplevel back in the tile it had.
    public func makeToplevel(title: String, restoreToken: String? = nil) -> HMToplevel {
        let surface = allocate()
        let id = allocate()
        send(HMOp.surfaceCreate, ["id": surface])
        var create: [String: Any] = ["id": id, "surface": surface]
        if let restoreToken { create["restore_token"] = restoreToken }
        send(HMOp.toplevelCreate, create)
        let t = HMToplevel(client: self, id: id, surfaceID: surface)
        toplevels[id] = t
        toplevelsBySurface[surface] = t
        t.setTitle(title)
        return t
    }

    func allocate() -> UInt64 { defer { nextID += 1 }; return nextID }

    func send(_ op: String, _ fields: [String: Any]) {
        guard let connection else { return }
        xpc_connection_send_message(connection, xpcMessage(op, fields))
    }

    fileprivate func register(_ surface: IOSurfaceRef) -> HMBuffer {
        let b = HMBuffer(surface: surface, id: allocate())
        buffers[b.id] = b
        send(HMOp.bufferCreateIOSurface, ["id": b.id, "surface": IOSurfaceCreateXPCObject(surface)])
        return b
    }

    fileprivate func destroy(_ b: HMBuffer) {
        buffers[b.id] = nil
        send(HMOp.bufferDestroy, ["id": b.id])
    }

    private func handle(_ m: xpc_object_t) {
        switch m.op {
        case HMOp.toplevelConfigure:
            toplevels[m.uint("id")]?.configure(HMConfigure(
                width: m.double("w"), height: m.double("h"), scale: m.double("scale"),
                states: Set(m.strings("states")), serial: m.uint("serial")))
        case HMOp.toplevelCloseRequested:
            toplevels[m.uint("id")]?.onCloseRequested?()
        case HMOp.surfaceFrameDone:
            frameCallbacks.removeValue(forKey: m.uint("callback"))?(m.double("target_time"))
        case HMOp.bufferRelease:
            guard let b = buffers[m.uint("id")] else { return }
            b.busy = false
            toplevels.values.forEach { $0.released(b) }
        case HMOp.pointerEnter:
            toplevelsBySurface[m.uint("surface")]?.onPointer?(.enter(x: m.double("x"), y: m.double("y")))
        case HMOp.pointerLeave:
            toplevelsBySurface[m.uint("surface")]?.onPointer?(.leave)
        case HMOp.pointerMotion:
            toplevelsBySurface[m.uint("surface")]?.onPointer?(.motion(x: m.double("x"), y: m.double("y"),
                                                                     buttons: m.uint("buttons"), modifiers: m.uint("modifiers")))
        case HMOp.pointerButton:
            toplevelsBySurface[m.uint("surface")]?.onPointer?(.button(
                x: m.double("x"), y: m.double("y"), button: Int(m.uint("button")), down: m.string("state") == "down",
                clickCount: Int(m.uint("click_count")), modifiers: m.uint("modifiers")))
        case HMOp.pointerScroll:
            toplevelsBySurface[m.uint("surface")]?.onPointer?(.scroll(
                x: m.double("x"), y: m.double("y"), dx: m.double("dx"), dy: m.double("dy"), precise: m.bool("precise"),
                phase: m.uint("phase"), momentumPhase: m.uint("momentum_phase"),
                ticksX: m.double("ticks_x"), ticksY: m.double("ticks_y")))
        case HMOp.keyboardEnter:
            toplevelsBySurface[m.uint("surface")]?.onKeyboardFocus?(true)
        case HMOp.keyboardLeave:
            toplevelsBySurface[m.uint("surface")]?.onKeyboardFocus?(false)
        case HMOp.keyboardKey:
            toplevelsBySurface[m.uint("surface")]?.onKey?(HMKeyEvent(
                keyCode: UInt16(m.uint("key_code")), down: m.string("state") == "down", isRepeat: m.bool("repeat"),
                characters: m.string("characters") ?? "", charactersIgnoringModifiers: m.string("characters_ignoring_modifiers") ?? "",
                modifiers: m.uint("modifiers")))
        case HMOp.keyboardModifiers:
            toplevelsBySurface[m.uint("surface")]?.onModifiers?(m.uint("modifiers"))
        case HMOp.textInputPreedit, HMOp.textInputCommit, HMOp.textInputDeleteSurrounding, HMOp.textInputDone:
            toplevelsBySurface[m.uint("surface")]?.textInputEvent(m)
        case HMOp.dialogResult:
            let json = m.string("result_json")?.data(using: .utf8)
            let result = json.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            dialogReplies.removeValue(forKey: m.uint("id"))?(result)
        case HMOp.menuSelected:
            menuReplies.removeValue(forKey: m.uint("id"))?(m.string("item"))
        case HMOp.error:
            onDisconnect?("\(m.string("code") ?? "error"): \(m.string("message") ?? "")")
        default:
            break
        }
    }
}

/// A tile. Draw into `acquireBuffer()`, then `present` it.
public final class HMToplevel {
    public let id: UInt64
    public let surfaceID: UInt64
    public private(set) var configuration: HMConfigure?
    public var onConfigure: ((HMConfigure) -> Void)?
    public var onCloseRequested: (() -> Void)?
    public var onPointer: ((HMPointerEvent) -> Void)?
    public var onKey: ((HMKeyEvent) -> Void)?
    public var onModifiers: ((UInt64) -> Void)?
    public var onKeyboardFocus: ((Bool) -> Void)?
    /// A swapchain buffer became free. Clients that skip frames while every buffer is
    /// busy should present their latest content here.
    public var onBufferReleased: (() -> Void)?
    private unowned let client: HMClient
    private var swapchain: [HMBuffer] = []
    private var unacked: UInt64?
    /// Buffers of an old size, destroyed once the compositor releases them.
    private var stale: [HMBuffer] = []
    public static let swapchainLength = 3

    init(client: HMClient, id: UInt64, surfaceID: UInt64) {
        self.client = client
        self.id = id
        self.surfaceID = surfaceID
    }

    public func setTitle(_ title: String) { client.send(HMOp.toplevelSetTitle, ["id": id, "title": title]) }
    public func setRestoreToken(_ token: String) { client.send(HMOp.toplevelSetRestoreToken, ["id": id, "token": token]) }

    /// Shows a native dialog over this tile. See `HMDialogKind` for options and results.
    public func openDialog(kind: String, options: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let rid = client.allocate()
        client.dialogReplies[rid] = reply
        let json = (try? JSONSerialization.data(withJSONObject: options)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        client.send(HMOp.dialogOpen, ["id": rid, "surface": surfaceID, "kind": kind, "options_json": json])
    }

    /// Pops up a native menu at a point in the tile (points, top-left). `reply` gets the
    /// picked item's id, or nil when the menu was dismissed.
    public func popupMenu(_ items: [[String: Any]], x: Double, y: Double, reply: @escaping (String?) -> Void) {
        let rid = client.allocate()
        client.menuReplies[rid] = reply
        let json = (try? JSONSerialization.data(withJSONObject: items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        client.send(HMOp.menuPopup, ["id": rid, "surface": surfaceID, "x": x, "y": y, "items_json": json])
    }
    public func setCursor(_ name: String) { client.send(HMOp.pointerSetCursor, ["name": name]) }

    // MARK: Text input

    /// Text input updates (IME, dead keys, the emoji picker, dictation). See HMTextInputUpdate.
    public var onTextInput: ((HMTextInputUpdate) -> Void)?
    private var pendingTextInput = HMTextInputUpdate()

    /// Turns on text input for this toplevel. With `compositorPreedit`, Hyprmux draws the
    /// composition itself, for clients that can't.
    public func enableTextInput(compositorPreedit: Bool = false) {
        client.send(HMOp.textInputEnable, ["surface": surfaceID, "preedit": compositorPreedit ? "compositor" : "client"])
    }
    public func disableTextInput() { client.send(HMOp.textInputDisable, ["surface": surfaceID]) }
    /// The caret in surface points (top-left origin), for the input method's candidate window.
    public func setTextInputCursorRect(x: Double, y: Double, width: Double, height: Double) {
        client.send(HMOp.textInputSetCursorRect, ["surface": surfaceID, "x": x, "y": y, "w": width, "h": height])
    }

    fileprivate func textInputEvent(_ m: xpc_object_t) {
        switch m.op {
        case HMOp.textInputDeleteSurrounding:
            pendingTextInput.deleteBefore += Int(m.uint("before"))
            pendingTextInput.deleteAfter += Int(m.uint("after"))
        case HMOp.textInputCommit:
            pendingTextInput.commit += m.string("text") ?? ""
        case HMOp.textInputPreedit:
            pendingTextInput.preedit = m.string("text") ?? ""
            let b = Int(m.uint("cursor_begin")), e = Int(m.uint("cursor_end"))
            pendingTextInput.preeditCursor = b..<max(b, e)
        case HMOp.textInputDone:
            var update = pendingTextInput
            update.serial = m.uint("serial")
            pendingTextInput = HMTextInputUpdate()
            onTextInput?(update)
        default:
            break
        }
    }

    fileprivate func configure(_ c: HMConfigure) {
        configuration = c
        unacked = c.serial
        onConfigure?(c)
    }

    /// A free buffer at the configured pixel size, or nil when all are in use.
    public func acquireBuffer() -> HMBuffer? {
        guard let c = configuration, c.pixelWidth > 0, c.pixelHeight > 0 else { return nil }
        // A new size retires the old swapchain.
        if let first = swapchain.first, first.width != c.pixelWidth || first.height != c.pixelHeight {
            for b in swapchain { if b.busy { stale.append(b) } else { client.destroy(b) } }
            swapchain.removeAll()
        }
        if let free = swapchain.first(where: { !$0.busy }) { return free }
        guard swapchain.count < Self.swapchainLength else { return nil }
        let props: [String: Any] = [
            kIOSurfaceWidth as String: c.pixelWidth, kIOSurfaceHeight as String: c.pixelHeight,
            kIOSurfaceBytesPerElement as String: 4, kIOSurfacePixelFormat as String: 0x4247_5241,  // 'BGRA'
        ]
        guard let s = IOSurfaceCreate(props as CFDictionary) else { return nil }
        let b = client.register(s)
        swapchain.append(b)
        return b
    }

    /// Shows `buffer`, acks the latest configure, and asks for a frame callback.
    /// `next` runs when it's time to draw again, with the target display time.
    public func present(_ buffer: HMBuffer, next: ((Double) -> Void)? = nil) {
        if let serial = unacked {
            client.send(HMOp.toplevelAckConfigure, ["id": id, "serial": serial])
            unacked = nil
        }
        buffer.busy = true
        let scale = configuration?.scale ?? 2
        client.send(HMOp.surfaceAttach, ["id": surfaceID, "buffer": buffer.id])
        client.send(HMOp.surfaceSetScale, ["id": surfaceID, "scale": scale])
        if let next {
            let cb = client.allocate()
            client.frameCallbacks[cb] = next
            client.send(HMOp.surfaceFrame, ["id": surfaceID, "callback": cb])
        }
        client.send(HMOp.surfaceCommit, ["id": surfaceID])
    }

    fileprivate func released(_ b: HMBuffer) {
        if let i = stale.firstIndex(where: { $0 === b }) {
            stale.remove(at: i)
            client.destroy(b)
        } else if swapchain.contains(where: { $0 === b }) {
            onBufferReleased?()
        }
    }

    public func destroy() {
        client.send(HMOp.toplevelDestroy, ["id": id])
        client.send(HMOp.surfaceDestroy, ["id": surfaceID])
        for b in swapchain + stale { client.destroy(b) }
        swapchain.removeAll()
        stale.removeAll()
        client.toplevels[id] = nil
        client.toplevelsBySurface[surfaceID] = nil
    }
}
