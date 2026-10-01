import AppKit
import HyprmuxClientProtocol
import IOSurface
import os
import XPC

private let clientLog = Logger(subsystem: "dev.gavrix.hyprmux", category: "clients")

/// What the server needs from the compositor.
protocol ClientServerHost: AnyObject {
    /// A toplevel no tile was reserved for: make and manage a new tile.
    func clientServer(_ server: ClientServer, newSurfaceFor appID: String, name: String) -> ClientSurface
    func clientServer(_ server: ClientServer, titleChanged surface: ClientSurface)
    func clientServer(_ server: ClientServer, notice message: String)
}

/// Accepts client connections (docs/CLIENT_PROTOCOL.md) and registers them with the broker.
final class ClientServer {
    weak var host: ClientServerHost?
    let instance = HMProtocol.currentInstance
    private var listener: xpc_connection_t?
    private var registrar: xpc_connection_t?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private(set) var registered = false
    private var warned = false
    /// Tiles waiting for a launched client, by launch token. A fresh launch reserves one
    /// tile; a restored session may reserve several, each with its restore token.
    private var reserved: [String: [ClientSurface]] = [:]
    /// What each launch ran (`new-surface --type app` text), for the session.
    private var launches: [String: String] = [:]

    func reserve(_ tiles: [ClientSurface], token: String, launch: String) {
        reserved[token, default: []] += tiles
        launches[token] = launch
    }

    func cancelReservation(_ token: String) -> [ClientSurface] {
        reserved.removeValue(forKey: token) ?? []
    }

    func reservedTiles(_ token: String) -> [ClientSurface] { reserved[token] ?? [] }

    func launchArgument(for token: String?) -> String? { token.flatMap { launches[$0] } }

    /// The tile a launched client's toplevel fills: the one saved with the same restore
    /// token, else the first one still waiting.
    func takeReserved(launch token: String?, restore: String?) -> ClientSurface? {
        guard let token, var tiles = reserved[token], !tiles.isEmpty else { return nil }
        let index = restore.flatMap { r in tiles.firstIndex { $0.restoreToken == r } } ?? 0
        let tile = tiles.remove(at: index)
        reserved[token] = tiles.isEmpty ? nil : tiles
        return tile
    }

    func start() {
        let listener = xpc_connection_create(nil, .main)
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard let self, xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            self.accept(event as xpc_connection_t)
        }
        xpc_connection_resume(listener)
        self.listener = listener
        // Clients started from our terminals find this instance.
        setenv(HMProtocol.instanceVariable, instance, 1)
        register()
    }

    /// Sends our endpoint to the broker. Retries when the broker restarts.
    private func register() {
        guard let listener else { return }
        let conn = xpc_connection_create_mach_service(HMProtocol.registrarService, .main, 0)
        xpc_connection_set_event_handler(conn) { [weak self] event in
            guard let self, xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            self.registered = false
            if event === XPC_ERROR_CONNECTION_INTERRUPTED {
                // The broker restarted: register again on the same connection.
                self.sendRegistration(on: conn, listener: listener)
            } else if event === XPC_ERROR_CONNECTION_INVALID {
                self.registrar = nil
                self.brokerUnavailable()
            }
        }
        xpc_connection_resume(conn)
        registrar = conn
        sendRegistration(on: conn, listener: listener)
    }

    private func sendRegistration(on conn: xpc_connection_t, listener: xpc_connection_t) {
        let message = xpcMessage(HMOp.register, ["instance": instance, "endpoint": xpc_endpoint_create(listener)])
        xpc_connection_send_message_with_reply(conn, message, .main) { [weak self] reply in
            guard let self else { return }
            if reply.isDictionary, reply.string("status") == "ok" {
                self.registered = true
                clientLog.info("registered client endpoint as instance '\(self.instance, privacy: .public)'")
            } else if reply.isDictionary {
                clientLog.error("broker refused registration: \(reply.string("status") ?? "?", privacy: .public)")
            }
        }
    }

    private func brokerUnavailable() {
        clientLog.info("hyprmux-broker is not loaded; client apps can't connect")
        // Retry quietly: scripts/dev-broker.sh may load it later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.registrar == nil else { return }
            self.register()
        }
    }

    /// Explains why an app tile can't connect, once.
    func warnIfUnavailable() {
        guard !registered, !warned else { return }
        warned = true
        host?.clientServer(self, notice: "Client apps need hyprmux-broker. Run scripts/dev-broker.sh load.")
    }

    private func accept(_ peer: xpc_connection_t) {
        let c = ClientConnection(peer: peer, server: self)
        connections[ObjectIdentifier(c)] = c
        c.onClose = { [weak self] c in self?.connections[ObjectIdentifier(c)] = nil }
        c.start()
    }

    var clientCount: Int { connections.count }
}

/// One client process. Holds its objects and turns messages into surface calls.
/// Everything runs on the main queue, in message order.
final class ClientConnection {
    final class Buffer {
        let id: UInt64
        let surface: IOSurfaceRef
        var busy = false
        var width: Int { IOSurfaceGetWidth(surface) }
        var height: Int { IOSurfaceGetHeight(surface) }
        init(id: UInt64, surface: IOSurfaceRef) { self.id = id; self.surface = surface }
    }

    /// Pending state of a `surface` object, applied on commit.
    private final class SurfaceState {
        var pendingBuffer: Buffer?
        var bufferAttached = false
        var pendingScale: CGFloat = 1
        var pendingCallbacks: [UInt64] = []
        var toplevel: UInt64 = 0
    }

    let peer: xpc_connection_t
    let pid: pid_t
    var onClose: ((ClientConnection) -> Void)?
    private weak var server: ClientServer?
    private var greeted = false
    private var appID = ""
    private var name = ""
    /// Every toplevel of a launched client may fill a tile reserved for its launch.
    private var launchToken: String?
    private var launchArgument: String?
    private var buffers: [UInt64: Buffer] = [:]
    private var surfaces: [UInt64: SurfaceState] = [:]
    /// Toplevel id → the tile showing it.
    private var toplevels: [UInt64: ClientSurface] = [:]
    private var closed = false

    init(peer: xpc_connection_t, server: ClientServer) {
        self.peer = peer
        self.server = server
        pid = xpc_connection_get_pid(peer)
    }

    func start() {
        xpc_connection_set_target_queue(peer, .main)
        xpc_connection_set_event_handler(peer) { [weak self] message in
            guard let self else { return }
            if message.isError { self.disconnected(); return }
            guard message.isDictionary else { return }
            self.handle(message)
        }
        xpc_connection_resume(peer)
    }

    func send(_ op: String, _ fields: [String: Any]) {
        guard !closed else { return }
        xpc_connection_send_message(peer, xpcMessage(op, fields))
    }

    /// A protocol error ends the connection, like `wl_display.error`.
    private func fail(_ code: String, _ message: String) {
        clientLog.error("client \(self.pid) (\(self.appID, privacy: .public)): \(code, privacy: .public): \(message, privacy: .public)")
        send(HMOp.error, ["code": code, "message": message])
        xpc_connection_cancel(peer)
        disconnected()
    }

    private func disconnected() {
        guard !closed else { return }
        closed = true
        for tile in toplevels.values { tile.clientLeft() }
        toplevels.removeAll()
        buffers.removeAll()
        surfaces.removeAll()
        onClose?(self)
    }

    /// The compositor closed a tile (after its close animation).
    func surfaceDestroyed(_ tile: ClientSurface) {
        for (id, t) in toplevels where t === tile { toplevels[id] = nil }
    }

    // MARK: Messages

    private func handle(_ m: xpc_object_t) {
        guard let op = m.op else { return fail("protocol", "message without op") }
        if !greeted {
            guard op == HMOp.hello else { return fail("protocol", "first message must be hello") }
            return hello(m)
        }
        let id = m.uint("id")
        switch op {
        case HMOp.bufferCreateIOSurface:
            guard buffers[id] == nil, id != 0 else { return fail("object", "buffer id \(id) in use") }
            guard let obj = m.value("surface"), let s = IOSurfaceLookupFromXPCObject(obj) else {
                return fail("buffer", "no IOSurface")
            }
            guard IOSurfaceGetPixelFormat(s) == 0x4247_5241 else { return fail("buffer", "v0 accepts only BGRA8") }
            buffers[id] = Buffer(id: id, surface: s)

        case HMOp.bufferDestroy:
            guard let b = buffers.removeValue(forKey: id) else { return fail("object", "no buffer \(id)") }
            for tile in toplevels.values { tile.bufferDestroyed(b) }

        case HMOp.surfaceCreate:
            guard surfaces[id] == nil, id != 0 else { return fail("object", "surface id \(id) in use") }
            surfaces[id] = SurfaceState()

        case HMOp.surfaceAttach:
            guard let s = surfaces[id] else { return fail("object", "no surface \(id)") }
            let bid = m.uint("buffer")
            if bid == 0 { s.pendingBuffer = nil; s.bufferAttached = true; break }
            guard let b = buffers[bid] else { return fail("object", "no buffer \(bid)") }
            s.pendingBuffer = b
            s.bufferAttached = true

        case HMOp.surfaceDamage, HMOp.surfaceSetOpaque:
            guard surfaces[id] != nil else { return fail("object", "no surface \(id)") }
            // Hints only: Core Animation redraws the whole layer.

        case HMOp.surfaceSetScale:
            guard let s = surfaces[id] else { return fail("object", "no surface \(id)") }
            let scale = m.double("scale")
            guard scale >= 1, scale <= 4 else { return fail("surface", "scale \(scale) out of range") }
            s.pendingScale = scale

        case HMOp.surfaceFrame:
            guard let s = surfaces[id] else { return fail("object", "no surface \(id)") }
            s.pendingCallbacks.append(m.uint("callback"))

        case HMOp.surfaceCommit:
            guard let s = surfaces[id] else { return fail("object", "no surface \(id)") }
            let callbacks = s.pendingCallbacks
            s.pendingCallbacks.removeAll()
            let buffer = s.bufferAttached ? s.pendingBuffer : nil
            s.bufferAttached = false
            if let tile = toplevels[s.toplevel] {
                tile.commit(buffer: buffer, scale: s.pendingScale, callbacks: callbacks)
            } else if !callbacks.isEmpty {
                // No role yet: answer callbacks right away so the client isn't stuck.
                for cb in callbacks { send(HMOp.surfaceFrameDone, ["callback": cb, "time": CACurrentMediaTime(), "target_time": CACurrentMediaTime()]) }
            }

        case HMOp.surfaceDestroy:
            guard let s = surfaces.removeValue(forKey: id) else { return fail("object", "no surface \(id)") }
            if let tile = toplevels.removeValue(forKey: s.toplevel) { tile.clientLeft() }

        case HMOp.toplevelCreate:
            let sid = m.uint("surface")
            guard let s = surfaces[sid] else { return fail("object", "no surface \(sid)") }
            guard toplevels[id] == nil, id != 0 else { return fail("object", "toplevel id \(id) in use") }
            guard s.toplevel == 0 else { return fail("role", "surface \(sid) already has a role") }
            guard let server, let host = server.host else { return }
            let restore = m.string("restore_token").flatMap { $0.isEmpty ? nil : $0 }
            let tile = server.takeReserved(launch: launchToken, restore: restore)
                ?? host.clientServer(server, newSurfaceFor: appID, name: name)
            s.toplevel = id
            toplevels[id] = tile
            tile.bind(connection: self, toplevel: id, surface: sid, appID: appID)
            tile.launchArgument = launchArgument
            tile.restoreToken = restore

        case HMOp.toplevelSetRestoreToken:
            guard let tile = toplevels[id] else { return fail("object", "no toplevel \(id)") }
            let token = m.string("token") ?? ""
            guard token.utf8.count <= 4096 else { return fail("toplevel", "restore token over 4 KiB") }
            tile.restoreToken = token.isEmpty ? nil : token

        case HMOp.dialogOpen:
            let sid = m.uint("surface")
            guard let tile = toplevels.values.first(where: { $0.surfaceID == sid }) else { return fail("object", "no toplevel for surface \(sid)") }
            let options = (m.string("options_json")?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            tile.showDialog(kind: m.string("kind") ?? "", options: options) { [weak self] result in
                let json = (try? JSONSerialization.data(withJSONObject: result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                self?.send(HMOp.dialogResult, ["id": id, "result_json": json])
            }

        case HMOp.menuPopup:
            let sid = m.uint("surface")
            guard let tile = toplevels.values.first(where: { $0.surfaceID == sid }) else { return fail("object", "no toplevel for surface \(sid)") }
            let items = (m.string("items_json")?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []
            tile.showMenu(items: items, at: CGPoint(x: m.double("x"), y: m.double("y"))) { [weak self] item in
                var fields: [String: Any] = ["id": id]
                if let item { fields["item"] = item }
                self?.send(HMOp.menuSelected, fields)
            }

        case HMOp.toplevelSetTitle:
            guard let tile = toplevels[id] else { return fail("object", "no toplevel \(id)") }
            tile.setClientTitle(m.string("title") ?? "")
            if let server { server.host?.clientServer(server, titleChanged: tile) }

        case HMOp.toplevelAckConfigure:
            guard let tile = toplevels[id] else { return fail("object", "no toplevel \(id)") }
            tile.ackConfigure(m.uint("serial"))

        case HMOp.toplevelDestroy:
            guard let tile = toplevels.removeValue(forKey: id) else { return fail("object", "no toplevel \(id)") }
            for s in surfaces.values where s.toplevel == id { s.toplevel = 0 }
            tile.clientLeft()

        case HMOp.textInputEnable, HMOp.textInputDisable, HMOp.textInputSetCursorRect:
            let sid = m.uint("surface")
            guard let tile = toplevels.values.first(where: { $0.surfaceID == sid }) else { return fail("object", "no toplevel for surface \(sid)") }
            switch op {
            case HMOp.textInputEnable: tile.setTextInput(enabled: true, compositorPreedit: m.string("preedit") == "compositor")
            case HMOp.textInputDisable: tile.setTextInput(enabled: false, compositorPreedit: false)
            default: tile.setTextCursorRect(CGRect(x: m.double("x"), y: m.double("y"), width: m.double("w"), height: m.double("h")))
            }

        case HMOp.pointerSetCursor:
            let name = m.string("name") ?? "arrow"
            for tile in toplevels.values { tile.setCursor(name) }

        default:
            fail("protocol", "unknown op \(op)")
        }
    }

    private func hello(_ m: xpc_object_t) {
        let version = m.uint("version")
        guard version >= HMProtocol.version else { return fail("version", "unsupported version \(version)") }
        appID = m.string("app_id") ?? ""
        name = m.string("name") ?? appID
        let token = m.string("launch_token") ?? ""
        launchToken = token.isEmpty ? nil : token
        launchArgument = server?.launchArgument(for: launchToken)
        greeted = true
        clientLog.info("client \(self.pid) connected: \(self.appID, privacy: .public)")
        if let reply = xpc_dictionary_create_reply(m) {
            xpcSet(reply, "op", "welcome")
            xpcSet(reply, "version", HMProtocol.version)
            xpcSet(reply, "scale", Double(NSScreen.main?.backingScaleFactor ?? 2))
            xpc_connection_send_message(peer, reply)
        }
    }
}
