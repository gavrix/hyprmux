import Foundation
import HyprmuxCore
import Network

/// The WebSocket endpoint CDP clients connect to, on the loopback address only.
///
/// Network I/O runs on its own queue; callbacks arrive on main. A connection that asks
/// for a path `accept` refuses, comes from a web page, or names a non-loopback host
/// gets an HTTP error instead of an upgrade.
final class AgentBrowserServer {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hyprmux-agent-browser")
    /// Accessed on `queue`.
    private var connections: [Int: Connection] = [:]
    private var nextID = 1

    /// Main thread. Return false to refuse the path.
    var accept: (_ connection: Int, _ path: String) -> Bool = { _, _ in false }
    var receive: (_ connection: Int, _ text: Data) -> Void = { _, _ in }
    var closed: (_ connection: Int) -> Void = { _ in }

    private final class Connection {
        let id: Int
        let nw: NWConnection
        var head = Data()
        var open = false
        var done = false
        var decoder = WebSocketDecoder()
        init(id: Int, nw: NWConnection) {
            self.id = id
            self.nw = nw
        }
    }

    /// Starts listening on 127.0.0.1. Port 0 picks a free one. Nil if it can't listen.
    init?(port requested: UInt16 = 0) {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requested) ?? .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        var failed = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed, .cancelled:
                failed = true
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.adopt(nw) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, !failed, let port = listener.port?.rawValue else {
            listener.cancel()
            return nil
        }
        self.port = port
        listener.stateUpdateHandler = nil
    }

    deinit { listener.cancel() }

    /// Sends one text message. Any thread.
    func send(_ connection: Int, _ text: Data) {
        queue.async {
            guard let c = self.connections[connection], c.open, !c.done else { return }
            c.nw.send(content: WebSocketEncoder.text(text), completion: .contentProcessed { _ in })
        }
    }

    /// Closes a connection with a close frame. Any thread.
    func close(_ connection: Int) {
        queue.async {
            guard let c = self.connections[connection] else { return }
            self.finish(c, frame: WebSocketEncoder.close(1000))
        }
    }

    // MARK: Queue

    private func adopt(_ nw: NWConnection) {
        let c = Connection(id: nextID, nw: nw)
        nextID += 1
        connections[c.id] = c
        nw.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .failed, .cancelled: self.finish(c, frame: nil)
            default: break
            }
        }
        nw.start(queue: queue)
        read(c)
    }

    private func read(_ c: Connection) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak c] data, _, complete, error in
            guard let self, let c, !c.done else { return }
            if let data, !data.isEmpty { self.handle(c, data) }
            if complete || error != nil {
                self.finish(c, frame: nil)
            } else if !c.done {
                self.read(c)
            }
        }
    }

    private func handle(_ c: Connection, _ data: Data) {
        guard c.open else { return handshake(c, data) }
        switch c.decoder.push(data) {
        case .failure:
            finish(c, frame: WebSocketEncoder.close(1002))
        case .success(let messages):
            for m in messages {
                switch m {
                case .text(let text), .binary(let text):
                    let id = c.id
                    DispatchQueue.main.async { self.receive(id, text) }
                case .ping(let payload):
                    c.nw.send(content: WebSocketEncoder.frame(opcode: 0xA, payload), completion: .contentProcessed { _ in })
                case .pong:
                    break
                case .close:
                    finish(c, frame: WebSocketEncoder.close(1000))
                    return
                }
            }
        }
    }

    private func handshake(_ c: Connection, _ data: Data) {
        c.head.append(data)
        switch WebSocketHandshake.parse(c.head) {
        case .success(nil):
            return
        case .failure(let e):
            finish(c, frame: WebSocketHandshake.reject(status: 400, e.description))
        case .success(let (request, consumed)?):
            if let refusal = WebSocketHandshake.refusal(request, port: port) {
                return finish(c, frame: WebSocketHandshake.reject(status: 403, refusal))
            }
            let id = c.id
            var accepted = false
            DispatchQueue.main.sync { accepted = self.accept(id, request.path) }
            guard accepted else {
                return finish(c, frame: WebSocketHandshake.reject(status: 404, "unknown endpoint; run `hyprmuxctl cdp-url`"))
            }
            let rest = c.head.dropFirst(consumed)
            c.head = Data()
            c.open = true
            c.nw.send(content: WebSocketHandshake.accept(request), completion: .contentProcessed { _ in })
            if !rest.isEmpty { handle(c, Data(rest)) }
        }
    }

    /// Sends a last frame (a close frame, or an HTTP error), then drops the connection.
    private func finish(_ c: Connection, frame: Data?) {
        guard !c.done else { return }
        c.done = true
        connections[c.id] = nil
        let wasOpen = c.open
        if let frame {
            c.nw.send(content: frame, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in c.nw.cancel() })
        } else {
            c.nw.cancel()
        }
        if wasOpen {
            let id = c.id
            DispatchQueue.main.async { self.closed(id) }
        }
    }
}
