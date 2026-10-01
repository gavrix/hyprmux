// Injects the hook into the app's main process through its Node inspector:
// launch with --inspect-brk, break on the app's first script under
// Contents/Resources/app, and `require` the hook there. Proven in
// prototypes/electron-embed; this is the same flow in Swift.
import Foundation

final class Injector {
    enum InjectionError: Error, LocalizedError {
        case inspectorDidNotAnswer
        case noScriptMatched(String)
        case evaluateFailed(String)

        var errorDescription: String? {
            switch self {
            case .inspectorDidNotAnswer: "the app's inspector didn't answer"
            case .noScriptMatched(let r): "no app script matched \(r)"
            case .evaluateFailed(let m): "injection failed: \(m)"
            }
        }
    }

    private var ws: URLSessionWebSocketTask?
    private var nextID = 0
    private var replies: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var scriptURLs: [String: String] = [:]   // scriptId -> url
    private var paused: CheckedContinuation<(String, String, String)?, Never>?  // (callFrameId, url, scriptId)

    /// Injects `hookPath` into the app listening on `port`. Returns after the hook is
    /// loaded; the app then closes the inspector itself.
    func inject(port: Int, hookPath: String, entryRegex: String, timeout: TimeInterval = 30) async throws {
        let targets = try await waitForInspector(port: port, deadline: timeout)
        guard let page = targets.first, let wsURL = page["webSocketDebuggerUrl"] as? String,
              let url = URL(string: wsURL) else { throw InjectionError.inspectorDidNotAnswer }
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
            let result = try await evaluateOn(frameID, expr)
            guard result == "injected" else { throw InjectionError.evaluateFailed(result) }
            _ = try await call("Debugger.resume")
            ws?.cancel(with: .normalClosure, reason: nil)
            return
        }
        throw InjectionError.noScriptMatched(entryRegex)
    }

    private func waitForInspector(port: Int, deadline: TimeInterval) async throws -> [[String: Any]] {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if let url = URL(string: "http://127.0.0.1:\(port)/json/list"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty {
                return list
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw InjectionError.inspectorDidNotAnswer
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        try await ws?.send(.string(String(decoding: data, as: UTF8.self)))
        return try await withCheckedThrowingContinuation { c in replies[id] = c }
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
        await withCheckedContinuation { c in paused = c }
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
                self.paused?.resume(returning: nil)
                self.paused = nil
                for (_, c) in self.replies { c.resume(throwing: InjectionError.inspectorDidNotAnswer) }
                self.replies.removeAll()
            }
        }
    }

    private func dispatch(_ m: [String: Any]) {
        if let id = m["id"] as? Int, let c = replies.removeValue(forKey: id) {
            c.resume(returning: m["result"] as? [String: Any] ?? [:])
            return
        }
        guard let method = m["method"] as? String else { return }
        switch method {
        case "Debugger.scriptParsed":
            if let p = m["params"] as? [String: Any], let sid = p["scriptId"] as? String {
                scriptURLs[sid] = p["url"] as? String ?? ""
            }
        case "Debugger.paused":
            guard let p = m["params"] as? [String: Any],
                  let frames = p["callFrames"] as? [[String: Any]], let f = frames.first,
                  let frameID = f["callFrameId"] as? String,
                  let location = f["location"] as? [String: Any],
                  let scriptID = location["scriptId"] as? String else { return }
            let url = (f["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? scriptURLs[scriptID] ?? ""
            paused?.resume(returning: (frameID, url, scriptID))
            paused = nil
        default:
            break
        }
    }
}
