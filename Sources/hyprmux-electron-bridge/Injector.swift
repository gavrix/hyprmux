// Injects the hook into the app's main process through its Node inspector:
// launch with --inspect-brk, break on the app's first script under
// Contents/Resources/app, and `require` the hook there. Proven in
// prototypes/electron-embed; this is the same flow in Swift. The hook closes the
// inspector as it loads (docs/ADAPTERS.md, "Security").
import Foundation

final class Injector: @unchecked Sendable {
    enum InjectionError: Error, LocalizedError {
        case inspectorDidNotAnswer
        case connectionClosed
        case noScriptMatched(String)
        case evaluateFailed(String)

        var errorDescription: String? {
            switch self {
            case .inspectorDidNotAnswer: "the app's inspector didn't answer"
            case .connectionClosed: "the app's inspector closed the connection"
            case .noScriptMatched(let r): "no app script matched \(r)"
            case .evaluateFailed(let m): "injection failed: \(m)"
            }
        }
    }

    private var ws: URLSessionWebSocketTask?
    private var nextID = 0
    /// The state below is shared with URLSession's delegate queue.
    private let lock = NSLock()
    private var closed = false
    private var replies: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var scriptURLs: [String: String] = [:]   // scriptId -> url
    private typealias Pause = (frameID: String, url: String, scriptID: String)
    private var paused: CheckedContinuation<Pause?, Never>?
    /// Pauses that arrived while nobody waited.
    private var pauses: [Pause] = []

    /// How the bridge found the inspector's WebSocket URL.
    enum URLSource { case stderr, http }

    /// Injects `hookPath` into the app listening on `port`. `stderrURL` returns the
    /// WebSocket URL once the app printed it; apps that publish it over HTTP too are
    /// found there as a fallback. Returns once the hook is loaded and has closed the
    /// inspector.
    @discardableResult
    func inject(port: Int, stderrURL: @escaping () -> String?, hookPath: String, entryRegex: String,
                timeout: TimeInterval = 30) async throws -> URLSource {
        let (wsURL, source) = try await waitForInspector(port: port, stderrURL: stderrURL, deadline: timeout)
        guard let url = URL(string: wsURL) else { throw InjectionError.inspectorDidNotAnswer }
        let task = URLSession(configuration: .default).webSocketTask(with: url)
        ws = task
        task.resume()
        receiveLoop()

        _ = try await call("Debugger.enable")
        _ = try await call("Debugger.setBreakpointByUrl", ["urlRegex": entryRegex, "lineNumber": 0])
        _ = try await call("Runtime.runIfWaitingForDebugger")

        var pauses = 0
        while pauses < 300 {
            guard let (frameID, url, _) = await waitForPaused() else { throw InjectionError.inspectorDidNotAnswer }
            pauses += 1
            guard !url.isEmpty, url.range(of: entryRegex, options: .regularExpression) != nil else {
                _ = try await call("Debugger.resume")
                continue
            }
            // CJS entry frames have require in scope (old Electron); newer ones have
            // process.getBuiltinModule.
            // `process?.` doesn't guard an unbound identifier, so test with typeof first.
            let probe = try await evaluateOn(frameID, "(typeof require === \"function\" ? \"req\" : typeof process !== \"undefined\" && typeof process.getBuiltinModule === \"function\" ? \"gbm\" : \"none\")")
            let escaped = hookPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let expr: String
            switch probe {
            case "req": expr = "require(\"\(escaped)\"), \"injected\""
            case "gbm": expr = "process.getBuiltinModule(\"module\").createRequire(\"\(escaped)\")(\"\(escaped)\"), \"injected\""
            default:
                _ = try await call("Debugger.resume")
                continue
            }
            // The hook closes the inspector before it returns, which ends this
            // connection with no reply. That is the normal outcome.
            let result: String
            do { result = try await evaluateOn(frameID, expr) } catch InjectionError.connectionClosed { return source }
            guard result == "injected" else { throw InjectionError.evaluateFailed(result) }
            // The hook loaded but left the inspector open. Resume; the bridge checks the port.
            _ = try? await call("Debugger.resume")
            ws?.cancel(with: .normalClosure, reason: nil)
            return source
        }
        throw InjectionError.noScriptMatched(entryRegex)
    }

    /// The URL from the app's stderr. An app whose inspector ignored
    /// --inspect-publish-uid also lists it on /json/list, as before the flag.
    private func waitForInspector(port: Int, stderrURL: () -> String?, deadline: TimeInterval) async throws -> (String, URLSource) {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if let url = stderrURL() { return (url, .stderr) }
            if let url = URL(string: "http://127.0.0.1:\(port)/json/list"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let ws = list.first?["webSocketDebuggerUrl"] as? String {
                return (ws, .http)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        throw InjectionError.inspectorDidNotAnswer
    }

    /// Whether the inspector's HTTP endpoint lists the WebSocket URL. With
    /// --inspect-publish-uid=stderr it answers 404.
    static func publishesOverHTTP(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("webSocketDebuggerUrl")
    }

    /// Sends a command and waits for its reply. The continuation is in place before the
    /// message goes out, so a reply or a close can't arrive before anyone waits.
    private func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        return try await withCheckedThrowingContinuation { c in
            let isClosed = lock.withLock {
                if !closed { replies[id] = c }
                return closed
            }
            if isClosed { c.resume(throwing: InjectionError.connectionClosed); return }
            ws?.send(.string(text)) { [weak self] error in
                guard error != nil, let self else { return }
                if let c = self.lock.withLock({ self.replies.removeValue(forKey: id) }) {
                    c.resume(throwing: InjectionError.connectionClosed)
                }
            }
        }
    }

    private func evaluateOn(_ frameID: String, _ expression: String) async throws -> String {
        let r = try await call("Debugger.evaluateOnCallFrame", ["callFrameId": frameID, "expression": expression, "returnByValue": true])
        if let exception = r["exceptionDetails"] as? [String: Any] {
            let inner = exception["exception"] as? [String: Any]
            return "exception: \(exception["text"] ?? "") \(inner?["description"] as? String ?? "")"
        }
        let result = r["result"] as? [String: Any] ?? [:]
        if let value = result["value"] { return String(describing: value) }
        return result["description"] as? String ?? "?"
    }

    private func waitForPaused() async -> (String, String, String)? {
        let pause: Pause? = await withCheckedContinuation { c in
            let ready: Pause?? = lock.withLock {
                if !pauses.isEmpty { return .some(pauses.removeFirst()) }
                if closed { return .some(nil) }
                paused = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
        return pause.map { ($0.frameID, $0.url, $0.scriptID) }
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if let data = text.data(using: .utf8),
                   let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.dispatch(m)
                }
                self.receiveLoop()
            case .success: self.receiveLoop()
            case .failure:
                let (waiter, waiting) = self.lock.withLock {
                    self.closed = true
                    defer { self.paused = nil; self.replies.removeAll() }
                    return (self.paused, Array(self.replies.values))
                }
                waiter?.resume(returning: nil)
                for c in waiting { c.resume(throwing: InjectionError.connectionClosed) }
            }
        }
    }

    private func dispatch(_ m: [String: Any]) {
        if let id = m["id"] as? Int {
            if let c = lock.withLock({ replies.removeValue(forKey: id) }) {
                c.resume(returning: m["result"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let method = m["method"] as? String else { return }
        switch method {
        case "Debugger.scriptParsed":
            if let p = m["params"] as? [String: Any], let sid = p["scriptId"] as? String {
                lock.withLock { scriptURLs[sid] = p["url"] as? String ?? "" }
            }
        case "Debugger.paused":
            guard let p = m["params"] as? [String: Any],
                  let frames = p["callFrames"] as? [[String: Any]], let f = frames.first,
                  let frameID = f["callFrameId"] as? String,
                  let location = f["location"] as? [String: Any],
                  let scriptID = location["scriptId"] as? String else { return }
            let (waiter, pause): (CheckedContinuation<Pause?, Never>?, Pause) = lock.withLock {
                let url = (f["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? scriptURLs[scriptID] ?? ""
                let pause = (frameID: frameID, url: url, scriptID: scriptID)
                let waiter = paused
                paused = nil
                if waiter == nil { pauses.append(pause) }
                return (waiter, pause)
            }
            waiter?.resume(returning: pause)
        default:
            break
        }
    }
}
