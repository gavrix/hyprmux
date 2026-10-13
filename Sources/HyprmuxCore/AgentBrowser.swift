import Foundation

// Agent browser control (docs/AUTOMATION.md): agents drive Chromium web tiles through
// the Chrome DevTools Protocol (CDP). Hyprmux serves a browser-level CDP endpoint and
// routes each message to one tile's in-process DevTools session, so Chromium never opens
// a remote-debugging port. This file is the routing; the app moves the bytes.

/// A CDP message: a JSON object. Requests and responses carry `id`, events carry `method`.
public typealias CDPMessage = [String: Any]

/// A web tile as agents see it: one CDP page target.
public struct AgentBrowserTarget: Equatable, Sendable {
    public var tile: UInt64
    /// Chromium's id for the tile's DevTools target, which is also its main frame's id.
    /// Clients rely on that: Playwright finds a page's main frame by its target id.
    public var targetID: String
    public var url: String
    public var title: String

    public init(tile: UInt64, targetID: String, url: String, title: String) {
        self.tile = tile
        self.targetID = targetID
        self.url = url
        self.title = title
    }
}

/// Which tiles one endpoint URL can reach.
public enum AgentBrowserScope: Equatable, Sendable {
    case all
    /// These tiles, plus the tiles a connection opens itself.
    case tiles(Set<UInt64>)
}

/// Feedback a tile shows while an agent drives it. Coordinates are CSS pixels in the
/// page's viewport, as Input.dispatchMouseEvent has them.
public enum AgentCursorEffect: Equatable, Sendable {
    case move(x: Double, y: Double)
    case press(x: Double, y: Double)
    case release(x: Double, y: Double)
    case typing
}

/// What the app must do after the router handled a message or a tile change.
public enum AgentBrowserAction {
    /// Send a message to an agent connection.
    case client(Int, CDPMessage)
    /// Send a message to a tile's DevTools session. `waitForCursor`: send it only after the
    /// tile's agent cursor arrives where the press happens, so the click matches what shows.
    case tile(UInt64, CDPMessage, waitForCursor: Bool)
    /// An agent attached to a tile that had none: start forwarding its DevTools messages
    /// and show that an agent controls it.
    case attach(UInt64)
    /// The last agent left a tile: stop forwarding and hide the agent's cursor.
    case release(UInt64)
    case cursor(UInt64, AgentCursorEffect)
    /// Target.createTarget: open a web tile, then call `tileCreated(request:target:)`.
    case openTile(url: String, request: Int)
    case closeTile(UInt64)
}

/// Routes CDP between agent connections and tiles.
///
/// Agents speak to a browser-level endpoint, the one `chrome --remote-debugging-port`
/// serves. A tile's DevTools session is page-level: it has no Target.getTargets or
/// Target.attachToTarget. The router answers those itself and multiplexes flattened
/// sessions: a session id an agent uses for a tile is the router's; child sessions
/// (out-of-process iframes, workers) keep the ids Chromium gives them.
///
/// Message ids sent to tiles come from one counter, so replies from a tile shared by
/// several connections find their way back.
public final class AgentBrowserRouter {
    /// Browser.getVersion's reply. The app fills in Chromium's version.
    public var product = "Chrome"
    public var userAgent = ""
    /// Targets listed first: the focused web tile, so an agent's first tab is the one the user sees.
    public var preferredTile: UInt64?

    private struct Connection {
        var scope: AgentBrowserScope
        var discover = false
        /// Browser-level Target.setAutoAttach: attach every tile in scope, now and later.
        var autoAttach = false
        /// Tiles whose user pressed Stop: auto-attach leaves them alone.
        var stopped: Set<UInt64> = []
        /// Tiles this connection opened with Target.createTarget; always in its scope.
        var opened: Set<UInt64> = []
    }

    private struct Session {
        let connection: Int
        let tile: UInt64
    }

    private struct Pending {
        let connection: Int
        let id: Any
        let sessionID: String?
        let tile: UInt64
        var method = ""
    }

    /// What agents left in a tile's DevTools session, to undo when the last one leaves.
    private struct Leftovers {
        var scripts: Set<String> = []
        var bindings: Set<String> = []
    }

    private var targets: [UInt64: AgentBrowserTarget] = [:]
    private var connections: [Int: Connection] = [:]
    /// Sessions the router made: an agent's handle on one tile.
    private var sessions: [String: Session] = [:]
    /// Sessions the user ended with Stop, so their next message says why it fails.
    private var stoppedSessions: Set<String> = []
    /// Child sessions Chromium attached inside a tile's session.
    private var childSessions: [String: UInt64] = [:]
    private var pending: [Int: Pending] = [:]
    private var leftovers: [UInt64: Leftovers] = [:]
    private var creates: [Int: (connection: Int, id: Any)] = [:]
    private var nextUpstreamID: Int
    private var nextCreate = 1
    private let makeSessionID: () -> String

    /// Ids sent to tiles start high: the tile's own DevTools users (credential fill) count from 1.
    public static let firstUpstreamID = 1 << 30

    public init(makeSessionID: @escaping () -> String = {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }) {
        self.makeSessionID = makeSessionID
        nextUpstreamID = Self.firstUpstreamID
    }

    /// Tiles with at least one agent session.
    public var attachedTiles: Set<UInt64> { Set(sessions.values.map(\.tile)) }

    public func isAttached(_ tile: UInt64) -> Bool { sessions.values.contains { $0.tile == tile } }

    public var connectionCount: Int { connections.count }

    // MARK: Connections

    public func connect(_ connection: Int, scope: AgentBrowserScope) {
        connections[connection] = Connection(scope: scope)
    }

    public func disconnect(_ connection: Int) -> [AgentBrowserAction] {
        guard connections.removeValue(forKey: connection) != nil else { return [] }
        let before = attachedTiles
        sessions = sessions.filter { $0.value.connection != connection }
        pending = pending.filter { $0.value.connection != connection }
        creates = creates.filter { $0.value.connection != connection }
        return releases(before)
    }

    /// One message from an agent. Malformed messages get an error reply when they have an id.
    public func receive(_ connection: Int, _ message: CDPMessage) -> [AgentBrowserAction] {
        guard connections[connection] != nil else { return [] }
        let id = message["id"]
        guard let id, Self.isProtocolID(id), let method = message["method"] as? String else {
            guard let id else { return [] }
            return [.client(connection, Self.error(id: id, code: -32600,
                                                    "Message must have integer 'id' and string 'method' properties"))]
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let sessionID = message["sessionId"] as? String else {
            return browserMethod(connection, id: id, method: method, params: params)
        }
        if let session = sessions[sessionID] {
            guard session.connection == connection else {
                return [.client(connection, Self.error(id: id, sessionID: sessionID, code: -32001,
                                                        "Session with given id not found."))]
            }
            return pageMethod(connection, session: session, sessionID: sessionID, id: id,
                              method: method, params: params, message: message)
        }
        if let tile = childSessions[sessionID], hasSession(connection, on: tile) {
            var upstream = message
            upstream["id"] = allocate(Pending(connection: connection, id: id, sessionID: sessionID, tile: tile))
            return [.tile(tile, upstream, waitForCursor: false)]
        }
        let text = stoppedSessions.contains(sessionID)
            ? "The user pressed Stop on this Hyprmux tile and ended agent control. Ask them before attaching again."
            : "Session with given id not found."
        return [.client(connection, Self.error(id: id, sessionID: sessionID, code: -32001, text))]
    }

    // MARK: Tiles

    public func tileOpened(_ target: AgentBrowserTarget) -> [AgentBrowserAction] {
        let isNew = targets[target.tile] == nil
        targets[target.tile] = target
        guard isNew else { return tileUpdated(target) }
        let before = attachedTiles
        var actions: [AgentBrowserAction] = []
        for (cid, c) in connections.sorted(by: { $0.key < $1.key }) where inScope(c, target.tile) {
            if c.discover {
                actions.append(.client(cid, Self.event("Target.targetCreated", ["targetInfo": info(target, attached: false)])))
            }
            if c.autoAttach, !c.stopped.contains(target.tile) {
                actions.append(attachSession(cid, target).1)
            }
        }
        return attaches(before) + actions
    }

    public func tileUpdated(_ target: AgentBrowserTarget) -> [AgentBrowserAction] {
        guard let old = targets[target.tile] else { return [] }
        targets[target.tile] = target
        guard old != target else { return [] }
        return connections.sorted(by: { $0.key < $1.key }).compactMap { cid, c in
            guard c.discover, inScope(c, target.tile) else { return nil }
            return .client(cid, Self.event("Target.targetInfoChanged",
                                           ["targetInfo": info(target, attached: isAttached(target.tile))]))
        }
    }

    public func tileClosed(_ tile: UInt64) -> [AgentBrowserAction] {
        guard let closed = targets[tile] else { return [] }
        leftovers[tile] = nil
        var actions = detachSessions(on: tile, reason: "target_closed")
        targets[tile] = nil
        for (cid, c) in connections.sorted(by: { $0.key < $1.key }) where c.discover && inScope(c, tile) {
            actions.append(.client(cid, Self.event("Target.targetDestroyed", ["targetId": closed.targetID])))
        }
        for cid in connections.keys {
            connections[cid]?.opened.remove(tile)
            connections[cid]?.stopped.remove(tile)
        }
        return actions
    }

    /// The user pressed Stop on the tile: every agent leaves it, and auto-attach won't return.
    public func stop(_ tile: UInt64) -> [AgentBrowserAction] {
        let before = attachedTiles
        for cid in connections.keys where hasSession(cid, on: tile) { connections[cid]?.stopped.insert(tile) }
        return detachSessions(on: tile, reason: "canceled_by_user") + releases(before)
    }

    /// Chromium's DevTools agent for the tile went away; replies still pending are lost.
    public func tileDevToolsDetached(_ tile: UInt64) -> [AgentBrowserAction] {
        let before = attachedTiles
        return detachSessions(on: tile, reason: "target_closed") + releases(before)
    }

    /// A message from a tile's DevTools session: a reply to a routed request, or an event.
    public func tileMessage(_ tile: UInt64, _ message: CDPMessage) -> [AgentBrowserAction] {
        if let id = message["id"] as? Int {
            // Not ours: another DevTools user of the tile (credential fill).
            guard let p = pending[id], p.tile == tile else { return [] }
            pending[id] = nil
            if p.method == "Page.addScriptToEvaluateOnNewDocument", p.sessionID.map({ sessions[$0] != nil }) == true,
               let script = (message["result"] as? [String: Any])?["identifier"] as? String {
                leftovers[tile, default: Leftovers()].scripts.insert(script)
            }
            var reply = message
            reply["id"] = p.id
            reply["sessionId"] = p.sessionID
            return [.client(p.connection, reply)]
        }
        guard let method = message["method"] as? String else { return [] }
        let params = message["params"] as? [String: Any] ?? [:]
        if let child = params["sessionId"] as? String {
            if method == "Target.attachedToTarget" { childSessions[child] = tile }
            if method == "Target.detachedFromTarget" { childSessions[child] = nil }
        }
        let tileSessions = sessions.filter { $0.value.tile == tile }.sorted { $0.key < $1.key }
        if message["sessionId"] is String {
            // A child session's event: once to each connection that has the tile.
            var seen: Set<Int> = []
            return tileSessions.compactMap { _, s in
                guard seen.insert(s.connection).inserted else { return nil }
                return .client(s.connection, message)
            }
        }
        return tileSessions.map { sid, s in
            var event = message
            event["sessionId"] = sid
            return .client(s.connection, event)
        }
    }

    /// The tile a Target.createTarget asked for is ready. It joins the asking connection's
    /// scope, then opens like any tile, then the request gets its reply.
    public func tileCreated(request: Int, target: AgentBrowserTarget) -> [AgentBrowserAction] {
        let c = creates.removeValue(forKey: request)
        if let c { connections[c.connection]?.opened.insert(target.tile) }
        let opened = tileOpened(target)
        guard let c else { return opened }
        return opened + [.client(c.connection, Self.result(id: c.id, ["targetId": target.targetID]))]
    }

    public func tileCreateFailed(request: Int, _ message: String) -> [AgentBrowserAction] {
        guard let c = creates.removeValue(forKey: request) else { return [] }
        return [.client(c.connection, Self.error(id: c.id, code: -32000, message))]
    }

    // MARK: Browser-level methods

    private func browserMethod(_ cid: Int, id: Any, method: String, params: [String: Any]) -> [AgentBrowserAction] {
        let reply = { (result: [String: Any]) -> [AgentBrowserAction] in [.client(cid, Self.result(id: id, result))] }
        let fail = { (code: Int, text: String) -> [AgentBrowserAction] in [.client(cid, Self.error(id: id, code: code, text))] }
        switch method {
        case "Browser.getVersion":
            return reply(["protocolVersion": "1.3", "product": product, "revision": "",
                          "userAgent": userAgent, "jsVersion": ""])
        // Agents don't quit Hyprmux, and downloads follow the user's settings.
        case "Browser.close", "Browser.setDownloadBehavior", "Browser.grantPermissions", "Browser.resetPermissions",
             "Browser.setPermission":
            return reply([:])
        case "Target.setDiscoverTargets":
            let discover = params["discover"] as? Bool ?? false
            let was = connections[cid]?.discover ?? false
            connections[cid]?.discover = discover
            var actions: [AgentBrowserAction] = []
            if discover, !was {
                actions = visibleTargets(cid).map {
                    .client(cid, Self.event("Target.targetCreated", ["targetInfo": info($0, attached: isAttached($0.tile))]))
                }
            }
            return actions + reply([:])
        case "Target.getTargets":
            return reply(["targetInfos": visibleTargets(cid).map { info($0, attached: isAttached($0.tile)) }])
        case "Target.getTargetInfo":
            guard let targetID = params["targetId"] as? String else {
                return reply(["targetInfo": ["targetId": "hyprmux-browser", "type": "browser", "title": "",
                                             "url": "", "attached": true, "canAccessOpener": false]])
            }
            guard let target = target(targetID, for: cid) else { return fail(-32602, "No target with given id found") }
            return reply(["targetInfo": info(target, attached: isAttached(target.tile))])
        case "Target.attachToTarget":
            guard let targetID = params["targetId"] as? String, let target = target(targetID, for: cid) else {
                return fail(-32602, "No target with given id found")
            }
            guard params["flatten"] as? Bool == true else {
                return fail(-32000, "Hyprmux supports only flattened sessions; pass flatten: true")
            }
            let before = attachedTiles
            connections[cid]?.stopped.remove(target.tile)
            let (sid, event) = attachSession(cid, target)
            return attaches(before) + [event] + reply(["sessionId": sid])
        case "Target.detachFromTarget":
            guard let sid = params["sessionId"] as? String, let s = sessions[sid], s.connection == cid else {
                return fail(-32602, "No session with given id")
            }
            let before = attachedTiles
            sessions[sid] = nil
            pending = pending.filter { !($0.value.connection == cid && $0.value.sessionID == sid) }
            return [.client(cid, Self.event("Target.detachedFromTarget",
                                            ["sessionId": sid, "targetId": targets[s.tile]?.targetID ?? ""]))]
                + reply([:]) + releases(before)
        case "Target.setAutoAttach":
            let on = params["autoAttach"] as? Bool == true && params["flatten"] as? Bool == true
            connections[cid]?.autoAttach = on
            guard on, let c = connections[cid] else { return reply([:]) }
            let before = attachedTiles
            var actions: [AgentBrowserAction] = []
            for t in visibleTargets(cid) where !c.stopped.contains(t.tile) && !hasSession(cid, on: t.tile) {
                actions.append(attachSession(cid, t).1)
            }
            return attaches(before) + actions + reply([:])
        case "Target.createTarget":
            let url = (params["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
            let request = nextCreate
            nextCreate += 1
            creates[request] = (cid, id)
            return [.openTile(url: url, request: request)]
        case "Target.closeTarget":
            guard let targetID = params["targetId"] as? String, let target = target(targetID, for: cid) else {
                return fail(-32602, "No target with given id found")
            }
            return [.closeTile(target.tile)] + reply(["success": true])
        // Hyprmux leaves focus with the user; agents work in background tiles.
        case "Target.activateTarget":
            guard let targetID = params["targetId"] as? String, target(targetID, for: cid) != nil else {
                return fail(-32602, "No target with given id found")
            }
            return reply([:])
        case "Target.getBrowserContexts":
            return reply(["browserContextIds": []])
        case "Target.createBrowserContext", "Target.disposeBrowserContext":
            return fail(-32000, "Hyprmux web tiles share one profile; browser contexts aren't supported")
        default:
            return fail(-32601, "'\(method)' wasn't found")
        }
    }

    private func pageMethod(_ cid: Int, session: Session, sessionID: String, id: Any, method: String,
                            params: [String: Any], message: CDPMessage) -> [AgentBrowserAction] {
        switch method {
        // The tile stays where it is; focusing it would take focus from the user.
        case "Page.bringToFront":
            return [.client(cid, Self.result(id: id, sessionID: sessionID, [:]))]
        default:
            break
        }
        var upstream = message
        upstream["sessionId"] = nil
        upstream["id"] = allocate(Pending(connection: cid, id: id, sessionID: sessionID, tile: session.tile, method: method))
        if method == "Runtime.addBinding", let name = params["name"] as? String {
            leftovers[session.tile, default: Leftovers()].bindings.insert(name)
        }
        let (effect, wait) = Self.cursorEffect(method, params)
        var actions: [AgentBrowserAction] = []
        if let effect { actions.append(.cursor(session.tile, effect)) }
        actions.append(.tile(session.tile, upstream, waitForCursor: wait))
        return actions
    }

    /// What an input command looks like on screen, and whether it waits for the cursor.
    static func cursorEffect(_ method: String, _ params: [String: Any]) -> (AgentCursorEffect?, Bool) {
        func number(_ key: String, in p: [String: Any]) -> Double? { (p[key] as? NSNumber)?.doubleValue }
        switch method {
        case "Input.dispatchMouseEvent":
            guard let x = number("x", in: params), let y = number("y", in: params) else { return (nil, false) }
            switch params["type"] as? String {
            case "mousePressed": return (.press(x: x, y: y), true)
            case "mouseReleased": return (.release(x: x, y: y), false)
            case "mouseMoved", "mouseWheel": return (.move(x: x, y: y), false)
            default: return (nil, false)
            }
        case "Input.dispatchTouchEvent", "Input.emulateTouchFromMouseEvent":
            if method == "Input.emulateTouchFromMouseEvent" {
                guard params["type"] as? String == "mousePressed",
                      let x = number("x", in: params), let y = number("y", in: params) else { return (nil, false) }
                return (.press(x: x, y: y), true)
            }
            guard params["type"] as? String == "touchStart",
                  let point = (params["touchPoints"] as? [[String: Any]])?.first,
                  let x = number("x", in: point), let y = number("y", in: point) else { return (nil, false) }
            return (.press(x: x, y: y), true)
        case "Input.insertText", "Input.imeSetComposition":
            return (.typing, false)
        case "Input.dispatchKeyEvent":
            let type = params["type"] as? String
            return (type == "keyDown" || type == "rawKeyDown" ? .typing : nil, false)
        default:
            return (nil, false)
        }
    }

    // MARK: Sessions

    /// A new session on the tile, and the Target.attachedToTarget event that announces it.
    private func attachSession(_ cid: Int, _ target: AgentBrowserTarget) -> (String, AgentBrowserAction) {
        let sid = makeSessionID()
        sessions[sid] = Session(connection: cid, tile: target.tile)
        return (sid, .client(cid, Self.event("Target.attachedToTarget", [
            "sessionId": sid, "targetInfo": info(target, attached: true), "waitingForDebugger": false,
        ])))
    }

    private func detachSessions(on tile: UInt64, reason: String) -> [AgentBrowserAction] {
        var actions: [AgentBrowserAction] = []
        for (sid, s) in sessions.sorted(by: { $0.key < $1.key }) where s.tile == tile {
            sessions[sid] = nil
            if reason == "canceled_by_user" {
                if stoppedSessions.count > 1000 { stoppedSessions.removeAll() }
                stoppedSessions.insert(sid)
            }
            actions.append(.client(s.connection, Self.event("Target.detachedFromTarget",
                                                            ["sessionId": sid, "targetId": targets[tile]?.targetID ?? ""])))
        }
        for (cid, p) in pending.sorted(by: { $0.key < $1.key }) where p.tile == tile {
            pending[cid] = nil
            actions.append(.client(p.connection, Self.error(id: p.id, sessionID: p.sessionID, code: -32000,
                                                            reason == "canceled_by_user"
                                                                ? "The user pressed Stop on this Hyprmux tile and ended agent control"
                                                                : "Target closed")))
        }
        childSessions = childSessions.filter { $0.value != tile }
        return actions
    }

    private func attaches(_ before: Set<UInt64>) -> [AgentBrowserAction] {
        attachedTiles.subtracting(before).sorted().map { .attach($0) }
    }

    /// Tiles no agent has any more: undo what agents changed in their DevTools session, then
    /// release them. Hyprmux shares one DevTools session per tile among all agents, so an
    /// enabled domain or an emulated setting would otherwise outlive the agent that set it:
    /// the next agent's Runtime.enable wouldn't report the page's contexts again, and the
    /// user would keep browsing with a paused request queue or a fake viewport.
    private func releases(_ before: Set<UInt64>) -> [AgentBrowserAction] {
        before.subtracting(attachedTiles).sorted().flatMap { tile -> [AgentBrowserAction] in
            guard targets[tile] != nil else { return [.release(tile)] }
            let left = leftovers.removeValue(forKey: tile) ?? Leftovers()
            var calls: [(String, [String: Any])] = left.scripts.sorted().map {
                ("Page.removeScriptToEvaluateOnNewDocument", ["identifier": $0])
            }
            calls += left.bindings.sorted().map { ("Runtime.removeBinding", ["name": $0]) }
            calls += Self.resets
            childSessions = childSessions.filter { $0.value != tile }
            return calls.map { method, params in
                let id = nextUpstreamID
                nextUpstreamID = nextUpstreamID >= Int(Int32.max) ? Self.firstUpstreamID : nextUpstreamID + 1
                return .tile(tile, ["id": id, "method": method, "params": params], waitForCursor: false)
            } + [.release(tile)]
        }
    }

    /// Calls that return a tile's DevTools session to how it was before any agent.
    static var resets: [(String, [String: Any])] { [
        ("Fetch.disable", [:]),
        ("Debugger.disable", [:]),
        ("Target.setAutoAttach", ["autoAttach": false, "waitForDebuggerOnStart": false]),
        ("Page.setLifecycleEventsEnabled", ["enabled": false]),
        ("Page.setInterceptFileChooserDialog", ["enabled": false]),
        ("Page.setBypassCSP", ["enabled": false]),
        ("Network.setExtraHTTPHeaders", ["headers": [String: Any]()]),
        ("Network.setBlockedURLs", ["urls": [String]()]),
        ("Network.setCacheDisabled", ["cacheDisabled": false]),
        ("Network.emulateNetworkConditions",
         ["offline": false, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1]),
        ("Security.setIgnoreCertificateErrors", ["ignore": false]),
        ("Emulation.clearDeviceMetricsOverride", [:]),
        ("Emulation.setEmulatedMedia", ["media": "", "features": [[String: Any]]()]),
        ("Emulation.setFocusEmulationEnabled", ["enabled": false]),
        ("Emulation.clearGeolocationOverride", [:]),
        ("Emulation.setTouchEmulationEnabled", ["enabled": false]),
        ("Emulation.setScriptExecutionDisabled", ["value": false]),
        ("Emulation.setCPUThrottlingRate", ["rate": 1]),
        ("Emulation.setTimezoneOverride", ["timezoneId": ""]),
        ("Emulation.setLocaleOverride", [:]),
        ("Emulation.setUserAgentOverride", ["userAgent": ""]),
        ("Emulation.setDefaultBackgroundColorOverride", [:]),
        ("Emulation.setAutoDarkModeOverride", [:]),
        ("Overlay.disable", [:]),
        ("CSS.disable", [:]),
        ("DOM.disable", [:]),
        ("Accessibility.disable", [:]),
        ("Log.disable", [:]),
        ("Network.disable", [:]),
        ("Runtime.disable", [:]),
        ("Page.disable", [:]),
    ] }

    private func hasSession(_ cid: Int, on tile: UInt64) -> Bool {
        sessions.values.contains { $0.connection == cid && $0.tile == tile }
    }

    private func allocate(_ p: Pending) -> Int {
        let id = nextUpstreamID
        nextUpstreamID = nextUpstreamID >= Int(Int32.max) ? Self.firstUpstreamID : nextUpstreamID + 1
        pending[id] = p
        return id
    }

    // MARK: Targets

    private func inScope(_ c: Connection, _ tile: UInt64) -> Bool {
        switch c.scope {
        case .all: return true
        case .tiles(let tiles): return tiles.contains(tile) || c.opened.contains(tile)
        }
    }

    private func visibleTargets(_ cid: Int) -> [AgentBrowserTarget] {
        guard let c = connections[cid] else { return [] }
        return targets.values.filter { inScope(c, $0.tile) }.sorted {
            if ($0.tile == preferredTile) != ($1.tile == preferredTile) { return $0.tile == preferredTile }
            return $0.tile < $1.tile
        }
    }

    private func target(_ targetID: String, for cid: Int) -> AgentBrowserTarget? {
        guard let t = targets.values.first(where: { $0.targetID == targetID }),
              let c = connections[cid], inScope(c, t.tile) else { return nil }
        return t
    }

    private func info(_ t: AgentBrowserTarget, attached: Bool) -> [String: Any] {
        ["targetId": t.targetID, "type": "page", "title": t.title, "url": t.url, "attached": attached,
         "canAccessOpener": false, "browserContextId": "hyprmux-default"]
    }

    // MARK: Messages

    static func isProtocolID(_ id: Any) -> Bool {
        guard let n = id as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue == n.doubleValue.rounded()
    }

    static func event(_ method: String, _ params: [String: Any]) -> CDPMessage {
        ["method": method, "params": params]
    }

    static func result(id: Any, sessionID: String? = nil, _ result: [String: Any]) -> CDPMessage {
        var m: CDPMessage = ["id": id, "result": result]
        if let sessionID { m["sessionId"] = sessionID }
        return m
    }

    static func error(id: Any, sessionID: String? = nil, code: Int, _ message: String) -> CDPMessage {
        var m: CDPMessage = ["id": id, "error": ["code": code, "message": message]]
        if let sessionID { m["sessionId"] = sessionID }
        return m
    }
}
