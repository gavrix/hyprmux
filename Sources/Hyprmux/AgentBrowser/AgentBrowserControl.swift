import AppKit
import ChromiumBridge
import HyprmuxCore
import Security
import os

/// What agent browser control needs from the compositor.
protocol AgentBrowserHost: AnyObject {
    /// Chromium web tiles, whether or not Chromium has created their browsers yet.
    var agentBrowserSurfaces: [ChromiumSurface] { get }
    func agentBrowserSurface(_ id: ClientID) -> ChromiumSurface?
    /// The focused web tile, listed first to agents.
    var agentBrowserPreferredTile: ClientID? { get }
    /// Opens a background web tile for Target.createTarget. Nil when web tiles use WebKit.
    func agentBrowserOpenTile(url: String) -> ClientID?
    func agentBrowserCloseTile(_ id: ClientID)
}

/// Lets agents drive Chromium web tiles over CDP (docs/AUTOMATION.md).
///
/// `hyprmuxctl cdp-url` starts a WebSocket endpoint on the loopback address. Its URL
/// holds a random token, so only processes that can reach Hyprmux's socket learn it.
/// Messages go through AgentBrowserRouter to each tile's in-process DevTools session:
/// Chromium never opens a remote-debugging port, and Hyprmux sees every input command,
/// which drives the tile's agent cursor.
final class AgentBrowserControl {
    private weak var host: AgentBrowserHost?
    private let router = AgentBrowserRouter()
    private var server: AgentBrowserServer?
    /// Endpoint path token → what it reaches.
    private var scopes: [String: AgentBrowserScope] = [:]
    private var tiles: [ClientID: Tile] = [:]
    /// Tiles Target.createTarget opened, until Chromium creates their browsers.
    private var creates: [ClientID: Int] = [:]
    /// Tiles whose DevTools target id is on its way.
    private var resolving: Set<ClientID> = []
    private let log = Logger(subsystem: "dev.gavrix.hyprmux", category: "agent-browser")
    /// HYPRMUX_CDP_LOG=FILE: every message in and out, shortened, for debugging clients.
    private let traffic: FileHandle? = ProcessInfo.processInfo.environment["HYPRMUX_CDP_LOG"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    private func trace(_ direction: String, _ data: Data) {
        guard let traffic else { return }
        let text = String(decoding: data.prefix(600), as: UTF8.self)
        traffic.write(Data("\(direction) \(text)\n".utf8))
    }

    /// One tracked tile. Messages to it wait while its cursor travels to a press.
    private final class Tile {
        weak var surface: ChromiumSurface?
        var target: AgentBrowserTarget
        var forwarding = false
        var holds = 0
        var queue: [Item] = []
        init(surface: ChromiumSurface, target: AgentBrowserTarget) {
            self.surface = surface
            self.target = target
        }
    }

    private enum Item {
        case message(CDPMessage, waitForCursor: Bool)
        case cursor(AgentCursorEffect)
    }

    init(host: AgentBrowserHost) {
        self.host = host
        // Clients read Chrome's version from the product (Playwright does).
        router.product = "Chrome/\(HMChromium.chromiumVersion)"
    }

    /// True while an agent has a session on the tile.
    func isControlled(_ id: ClientID) -> Bool { router.isAttached(id.raw) }

    // MARK: Endpoint

    /// The endpoint's URL for a scope, starting the endpoint if needed.
    func endpointURL(scope: AgentBrowserScope) -> Result<String, ParseError> {
        if server == nil {
            guard let s = AgentBrowserServer() else { return .failure(ParseError("can't listen on the loopback address")) }
            s.accept = { [weak self] id, path in self?.accept(id, path: path) ?? false }
            s.receive = { [weak self] id, text in self?.receive(id, text) }
            s.closed = { [weak self] id in self?.perform(self?.router.disconnect(id) ?? []) }
            server = s
            for surface in host?.agentBrowserSurfaces ?? [] where surface.isBrowserReady { tileReady(surface) }
            log.info("agent browser endpoint on port \(s.port)")
        }
        guard let server else { return .failure(ParseError("endpoint unavailable")) }
        let token = scopes.first { $0.value == scope }?.key ?? Self.token()
        scopes[token] = scope
        return .success("ws://127.0.0.1:\(server.port)/devtools/browser/\(token)")
    }

    private static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func accept(_ connection: Int, path: String) -> Bool {
        let prefix = "/devtools/browser/"
        guard path.hasPrefix(prefix), let scope = scopes[String(path.dropFirst(prefix.count))] else { return false }
        router.connect(connection, scope: scope)
        log.info("agent connected (\(connection))")
        return true
    }

    private func receive(_ connection: Int, _ text: Data) {
        trace("agent\(connection) >", text)
        guard let message = (try? JSONSerialization.jsonObject(with: text)) as? CDPMessage else { return }
        router.preferredTile = host?.agentBrowserPreferredTile?.raw
        perform(router.receive(connection, message))
    }

    // MARK: Tiles

    /// Chromium created the tile's browser. Agents see it once its DevTools target id is known.
    func tileReady(_ surface: ChromiumSurface) {
        let id = surface.clientID
        guard server != nil || creates[id] != nil, tiles[id] == nil, resolving.insert(id).inserted else { return }
        surface.fetchDevToolsTargetID { [weak self, weak surface] targetID in
            guard let self else { return }
            self.resolving.remove(id)
            guard let surface, let targetID, self.host?.agentBrowserSurface(id) === surface else {
                if let request = self.creates.removeValue(forKey: id) {
                    self.perform(self.router.tileCreateFailed(request: request, "Chromium didn't report the new tile's target"))
                }
                return
            }
            let target = AgentBrowserTarget(tile: id.raw, targetID: targetID, url: surface.currentURL, title: surface.title)
            self.tiles[id] = Tile(surface: surface, target: target)
            surface.onAgentStop = { [weak self] in self?.perform(self?.router.stop(id.raw) ?? []) }
            if let request = self.creates.removeValue(forKey: id) {
                self.perform(self.router.tileCreated(request: request, target: target))
            } else {
                self.perform(self.router.tileOpened(target))
            }
        }
    }

    /// Title or URL changed.
    func tileChanged(_ surface: BrowserSurface) {
        guard let t = tiles[surface.clientID] else { return }
        t.target.url = surface.currentURL
        t.target.title = surface.title
        perform(router.tileUpdated(t.target))
    }

    func tileClosed(_ id: ClientID) {
        if let request = creates.removeValue(forKey: id) {
            perform(router.tileCreateFailed(request: request, "The tile closed before it loaded"))
        }
        guard let t = tiles.removeValue(forKey: id) else { return }
        t.surface?.onDevToolsMessage = nil
        t.surface?.onDevToolsDetached = nil
        perform(router.tileClosed(id.raw))
    }

    // MARK: Actions

    private func perform(_ actions: [AgentBrowserAction]) {
        for action in actions {
            switch action {
            case .client(let connection, let message):
                guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
                else { continue }
                trace("agent\(connection) <", data)
                server?.send(connection, data)
            case .tile(let tile, let message, let wait):
                enqueue(ClientID(tile), .message(message, waitForCursor: wait))
            case .cursor(let tile, let effect):
                enqueue(ClientID(tile), .cursor(effect))
            case .attach(let tile):
                attach(ClientID(tile))
            case .release(let tile):
                release(ClientID(tile))
            case .openTile(let url, let request):
                guard let id = host?.agentBrowserOpenTile(url: url) else {
                    perform(router.tileCreateFailed(request: request, "Agent browser control needs web:engine = chromium"))
                    continue
                }
                creates[id] = request
                // The browser may already exist (it's created when the tile joins the window).
                if let s = host?.agentBrowserSurface(id), s.isBrowserReady { tileReady(s) }
            case .closeTile(let tile):
                host?.agentBrowserCloseTile(ClientID(tile))
            }
        }
    }

    private func attach(_ id: ClientID) {
        guard let t = tiles[id], let s = t.surface else { return }
        s.onDevToolsMessage = { [weak self] data in self?.tileMessage(id, data) }
        s.onDevToolsDetached = { [weak self] in self?.perform(self?.router.tileDevToolsDetached(id.raw) ?? []) }
        t.forwarding = s.startDevToolsForwarding()
        guard t.forwarding else {
            log.error("Chromium refused DevTools forwarding for tile \(id.raw)")
            return perform(router.tileDevToolsDetached(id.raw))
        }
        s.setAgentControlled(true)
    }

    private func release(_ id: ClientID) {
        guard let t = tiles[id] else { return }
        // Send what's queued (the router's reset of the tile's session) before forwarding stops.
        t.holds = 0
        drain(t)
        t.forwarding = false
        t.surface?.stopDevToolsForwarding()
        t.surface?.onDevToolsMessage = nil
        t.surface?.onDevToolsDetached = nil
        t.surface?.setAgentControlled(false)
    }

    private func tileMessage(_ id: ClientID, _ data: Data) {
        trace("tile\(id.raw) >", data)
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? CDPMessage else { return }
        perform(router.tileMessage(id.raw, message))
    }

    // MARK: Cursor and ordering

    private func enqueue(_ id: ClientID, _ item: Item) {
        guard let t = tiles[id] else { return }
        t.queue.append(item)
        drain(t)
    }

    /// Runs queued items in order. A press holds everything after it until the cursor
    /// reaches the press point, then the press goes to Chromium.
    private func drain(_ t: Tile) {
        while t.holds == 0, !t.queue.isEmpty {
            let item = t.queue.removeFirst()
            switch item {
            case .message(let message, _):
                send(message, to: t)
            case .cursor(let effect):
                guard let s = t.surface else { continue }
                switch effect {
                case .move(let x, let y):
                    s.agentCursorMove(toPage: CGPoint(x: x, y: y), zoom: s.zoomFactor)
                case .press(let x, let y):
                    t.holds += 1
                    s.agentCursorMove(toPage: CGPoint(x: x, y: y), zoom: s.zoomFactor) { [weak self, weak t] in
                        guard let self, let t else { return }
                        t.surface?.agentCursorPress()
                        t.holds = max(0, t.holds - 1)
                        self.drain(t)
                    }
                case .release:
                    break
                case .typing:
                    s.agentCursorTyping()
                }
            }
        }
    }

    private func send(_ message: CDPMessage, to t: Tile) {
        if let s = t.surface, t.forwarding,
           let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]),
           s.sendDevToolsMessage(data) {
            trace("tile\(t.target.tile) <", data)
            return
        }
        // The agent still gets a reply, so it doesn't wait for one forever.
        perform(router.tileMessage(t.target.tile, [
            "id": message["id"] ?? 0, "error": ["code": -32000, "message": "Chromium refused the message"],
        ]))
    }
}
