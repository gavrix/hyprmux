import AppKit
import HyprmuxClientProtocol
import IOSurface
import os
import XPC

private let clientLog = Logger(subsystem: "dev.gavrix.hyprmux", category: "clients")

/// What the server needs from the compositor.
protocol ClientServerHost: AnyObject {
    /// A toplevel no restored tile waits for: make and place a new tile. `launch` is the
    /// launch it answers, if any.
    func clientServer(_ server: ClientServer, newSurfaceFor appID: String, name: String, launch: AppLaunch?) -> ClientSurface
    /// A toplevel of `launch` took its tile.
    func clientServer(_ server: ClientServer, opened tile: ClientSurface, for launch: AppLaunch)
    /// The app offered windows for a launch (`launch.offer`).
    func clientServer(_ server: ClientServer, offered windows: [HMWindowOffer], for launch: AppLaunch)
    /// The app said a launch gets no more windows (`launch.done`).
    func clientServer(_ server: ClientServer, finished launch: AppLaunch)
    /// The connection a launch went to closed before the launch got a window.
    func clientServer(_ server: ClientServer, lost launch: AppLaunch)
    func clientServer(_ server: ClientServer, titleChanged surface: ClientSurface)
    /// An app tile waits for a client, but Hyprmux isn't registered with the broker.
    /// Called once per launch; the host explains what the user can do.
    func clientServerUnavailable(_ server: ClientServer)
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
    /// Launches by token: pending ones, and settled ones whose app is still connected
    /// (later windows of a launch are stamped with it).
    private var launches: [String: AppLaunch] = [:]
    /// Single-instance apps by id: the process Hyprmux started, its connection once it
    /// says hello, and launches that wait for that hello.
    private var singles: [String: SingleInstance] = [:]

    final class SingleInstance {
        var process: Process?
        /// The launch token the process started with: its hello names it.
        let token: String
        weak var connection: ClientConnection?
        var queued: [AppLaunch] = []
        init(process: Process?, token: String) {
            self.process = process
            self.token = token
        }
    }

    func add(_ launch: AppLaunch) { launches[launch.token] = launch }

    func remove(_ launch: AppLaunch) {
        launches[launch.token] = nil
        for single in singles.values { single.queued.removeAll { $0 === launch } }
    }

    func launch(for token: String?) -> AppLaunch? { token.flatMap { launches[$0] } }

    /// The running (or starting) process of a single-instance app.
    func single(_ appID: String) -> SingleInstance? { singles[appID] }

    func setSingle(_ appID: String, _ instance: SingleInstance?) { singles[appID] = instance }

    /// Sends `launch` to the single-instance app's process now, or once it connects.
    func deliver(_ launch: AppLaunch, to instance: SingleInstance) {
        if let c = instance.connection { launch.sendLaunch(on: c) } else { instance.queued.append(launch) }
    }

    /// A connection said hello: it answers its own launch, and the launches queued for
    /// its app.
    fileprivate func greeted(_ connection: ClientConnection, token: String?) {
        guard let token else { return }
        var deliver: [AppLaunch] = []
        // The first launch may be gone already (dismissed while the app started).
        if let launch = launch(for: token) { deliver.append(launch) }
        if let single = singles.values.first(where: { $0.token == token }) {
            single.connection = connection
            deliver += single.queued
            single.queued.removeAll()
        }
        for l in deliver where l.pending { l.sendLaunch(on: connection) }
    }

    fileprivate func closed(_ connection: ClientConnection) {
        for (id, single) in singles where single.connection === connection { singles[id] = nil }
        for l in launches.values where l.connection === connection {
            launches[l.token] = nil
            if l.pending { host?.clientServer(self, lost: l) }
        }
    }

    /// The process a single-instance launch started ended.
    func processEnded(_ process: Process) {
        for (id, single) in singles where single.process === process { singles[id] = nil }
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
        // Retry quietly: the agent may be approved, or scripts/dev-broker.sh load it, later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.registrar == nil else { return }
            self.register()
        }
    }

    /// Tries the broker now instead of at the next retry (the agent was just enabled).
    func retryNow() {
        guard listener != nil, registrar == nil else { return }
        register()
    }

    /// Explains why an app tile can't connect, once.
    func warnIfUnavailable() {
        guard !registered, !warned else { return }
        warned = true
        host?.clientServerUnavailable(self)
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
        /// Set when the surface is a subsurface: its object id.
        var subsurface: UInt64 = 0
    }

    /// A `subsurface` object: a surface drawn above its parent, scaled to a rect.
    private final class SubsurfaceState {
        let surface: UInt64
        let parent: UInt64
        var pendingRect: CGRect?
        init(surface: UInt64, parent: UInt64) { self.surface = surface; self.parent = parent }
    }

    let peer: xpc_connection_t
    let pid: pid_t
    var onClose: ((ClientConnection) -> Void)?
    private weak var server: ClientServer?
    private var greeted = false
    private var appID = ""
    private var name = ""
    /// The launch that started the process: toplevels that name no launch belong to it.
    private var launchToken: String?
    private var buffers: [UInt64: Buffer] = [:]
    private var surfaces: [UInt64: SurfaceState] = [:]
    /// Toplevel id → the tile showing it.
    private var toplevels: [UInt64: ClientSurface] = [:]
    private var subsurfaces: [UInt64: SubsurfaceState] = [:]
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
        subsurfaces.removeAll()
        server?.closed(self)
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
            if s.subsurface != 0, let sub = subsurfaces[s.subsurface], let tile = tile(forSurface: sub.parent) {
                tile.commitChild(s.subsurface, buffer: buffer, callbacks: callbacks)
            } else if let tile = toplevels[s.toplevel] {
                tile.commit(buffer: buffer, scale: s.pendingScale, callbacks: callbacks)
                // Subsurface rects take effect with the parent's commit.
                for (sid, sub) in subsurfaces where sub.parent == id {
                    guard let r = sub.pendingRect else { continue }
                    sub.pendingRect = nil
                    tile.setChildRect(sid, r)
                }
            } else if !callbacks.isEmpty {
                // No role yet: answer callbacks right away so the client isn't stuck.
                for cb in callbacks { send(HMOp.surfaceFrameDone, ["callback": cb, "time": CACurrentMediaTime(), "target_time": CACurrentMediaTime()]) }
            }

        case HMOp.surfaceDestroy:
            guard let s = surfaces.removeValue(forKey: id) else { return fail("object", "no surface \(id)") }
            if s.subsurface != 0 { destroySubsurface(s.subsurface) }
            if let tile = toplevels.removeValue(forKey: s.toplevel) { tile.clientLeft() }

        case HMOp.subsurfaceCreate:
            let sid = m.uint("surface"), pid = m.uint("parent")
            guard subsurfaces[id] == nil, id != 0 else { return fail("object", "subsurface id \(id) in use") }
            guard let s = surfaces[sid] else { return fail("object", "no surface \(sid)") }
            guard let parent = surfaces[pid] else { return fail("object", "no surface \(pid)") }
            guard s.toplevel == 0, s.subsurface == 0, sid != pid else { return fail("role", "surface \(sid) already has a role") }
            guard parent.subsurface == 0 else { return fail("role", "a subsurface can't have subsurfaces") }
            s.subsurface = id
            subsurfaces[id] = SubsurfaceState(surface: sid, parent: pid)

        case HMOp.subsurfaceSetRect:
            guard let sub = subsurfaces[id] else { return fail("object", "no subsurface \(id)") }
            let r = CGRect(x: m.double("x"), y: m.double("y"), width: m.double("w"), height: m.double("h"))
            guard r.width >= 0, r.height >= 0, r.minX.isFinite, r.minY.isFinite else {
                return fail("subsurface", "bad rect")
            }
            sub.pendingRect = r

        case HMOp.subsurfaceDestroy:
            guard subsurfaces[id] != nil else { return fail("object", "no subsurface \(id)") }
            destroySubsurface(id)

        case HMOp.launchOffer, HMOp.launchDone:
            guard let server, let host = server.host else { return }
            // Unknown or ended launches are fine: the user may have dismissed it.
            guard let launch = server.launch(for: m.string("launch_token")), launch.connection === self else { return }
            if op == HMOp.launchDone {
                host.clientServer(server, finished: launch)
            } else {
                host.clientServer(server, offered: HMWindowOffer.decode(m.string("windows_json")), for: launch)
            }

        case HMOp.toplevelCreate:
            let sid = m.uint("surface")
            guard let s = surfaces[sid] else { return fail("object", "no surface \(sid)") }
            guard toplevels[id] == nil, id != 0 else { return fail("object", "toplevel id \(id) in use") }
            guard s.toplevel == 0 else { return fail("role", "surface \(sid) already has a role") }
            guard s.subsurface == 0 else { return fail("role", "surface \(sid) already has a role") }
            guard let server, let host = server.host else { return }
            let restore = m.string("restore_token").flatMap { $0.isEmpty ? nil : $0 }
            let named = m.string("launch_token").flatMap { $0.isEmpty ? nil : $0 }
            // A launch answers only through the connection it went to.
            let launch = server.launch(for: named ?? launchToken).flatMap { $0.connection === self ? $0 : nil }
            let reserved = launch?.takeReserved(restore: restore)
            let tile = reserved ?? host.clientServer(server, newSurfaceFor: appID, name: name, launch: launch)
            s.toplevel = id
            toplevels[id] = tile
            tile.bind(connection: self, toplevel: id, surface: sid, appID: appID)
            if let launch {
                launch.stamp(tile)
            } else {
                tile.launchArgument = nil
            }
            tile.restoreToken = restore
            if let launch { host.clientServer(server, opened: tile, for: launch) }

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
        greeted = true
        clientLog.info("client \(self.pid) connected: \(self.appID, privacy: .public)")
        if let reply = xpc_dictionary_create_reply(m) {
            xpcSet(reply, "op", "welcome")
            xpcSet(reply, "version", HMProtocol.version)
            xpcSet(reply, "scale", Double(NSScreen.main?.backingScaleFactor ?? 2))
            xpc_connection_send_message(peer, reply)
        }
        server?.greeted(self, token: launchToken)
    }

    private func tile(forSurface sid: UInt64) -> ClientSurface? {
        guard let s = surfaces[sid] else { return nil }
        return toplevels[s.toplevel]
    }

    private func destroySubsurface(_ id: UInt64) {
        guard let sub = subsurfaces.removeValue(forKey: id) else { return }
        surfaces[sub.surface]?.subsurface = 0
        tile(forSurface: sub.parent)?.removeChild(id)
    }
}
