import Foundation
import HyprmuxClientProtocol
import HyprmuxCore
import os
import ServiceManagement
import XPC

private let brokerLog = Logger(subsystem: "dev.gavrix.hyprmux", category: "broker")

/// Registers the bundled `hyprmux-broker` launch agent with `SMAppService`, so app tiles
/// work without developer steps (docs/CLIENT_PROTOCOL.md, section 3).
///
/// The rule, on every launch:
/// - Not inside an `.app` (a SwiftPM build run from `.build`): skip, silently.
/// - `misc:register_broker = false`: skip.
/// - Our agent is enabled, or waits for the user's approval: nothing to register.
/// - The lookup service already exists although our agent isn't enabled: another job
///   holds the broker label. That is the dev broker (`scripts/dev-broker.sh`) or another
///   Hyprmux copy's agent. Skip, so the two don't collide.
/// - Otherwise call `register()` and report what macOS says.
///
/// Checks run off the main thread (the lookup ping waits for launchd); results arrive on main.
final class BrokerRegistration {
    static let plistName = HMProtocol.brokerLabel + ".plist"

    enum Outcome: Equatable {
        case notChecked
        /// Not running from an app bundle.
        case notBundled
        /// `misc:register_broker = false`.
        case disabled
        /// Another job holds the broker label (the dev broker, or another copy's agent).
        case otherBroker
        case enabled
        /// Registered, but the user has to allow it in Login Items.
        case requiresApproval
        /// `register()` failed; the system's reason.
        case failed(String)
        /// The bundle lacks `Contents/Library/LaunchAgents/<plist>`.
        case notFound

        var name: String {
            switch self {
            case .notChecked: return "not-checked"
            case .notBundled: return "not-bundled"
            case .disabled: return "disabled"
            case .otherBroker: return "other-broker"
            case .enabled: return "enabled"
            case .requiresApproval: return "requires-approval"
            case .failed: return "failed"
            case .notFound: return "not-found"
            }
        }
    }

    private(set) var outcome: Outcome = .notChecked
    /// The outcome changed: (old, new). On the main queue.
    var onChange: ((Outcome, Outcome) -> Void)?
    private let queue = DispatchQueue(label: "dev.gavrix.hyprmux.broker-registration")
    private var checking = false

    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// Whether Hyprmux runs from an app bundle, which is the only place SMAppService finds the agent.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var plistURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
    }

    /// Checks the agent and registers it when the rule says so. `setting` is
    /// `misc:register_broker`.
    func update(setting: Bool) {
        guard Self.isBundled else { return set(.notBundled) }
        guard setting else { return set(.disabled) }
        guard !checking else { return }
        checking = true
        queue.async { [weak self] in
            let result = Self.check()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.set(result)
            }
        }
    }

    /// Re-reads the status without registering, e.g. when Hyprmux becomes active while
    /// approval is pending.
    func recheck() {
        guard outcome == .requiresApproval, !checking else { return }
        checking = true
        queue.async { [weak self] in
            let status = Self.service.status
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                switch status {
                case .enabled: self.set(.enabled)
                case .requiresApproval: break
                default: self.set(.notChecked)
                }
            }
        }
    }

    /// `hyprmuxctl broker register|unregister` changed the agent directly: take what
    /// macOS reports now. Main queue.
    func adopt(_ status: SMAppService.Status) {
        switch status {
        case .enabled: set(.enabled)
        case .requiresApproval: set(.requiresApproval)
        default: set(.notChecked)
        }
    }

    private func set(_ new: Outcome) {
        let old = outcome
        outcome = new
        if old != new {
            brokerLog.info("broker agent: \(new.name, privacy: .public)")
            onChange?(old, new)
        }
    }

    /// The rule above. Runs off the main thread.
    private static func check() -> Outcome {
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            brokerLog.error("no broker launch agent at \(plistURL.path, privacy: .public)")
            return .notFound
        }
        let service = Self.service
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return lookupServiceExists() ? .otherBroker : .requiresApproval
        default: break
        }
        if lookupServiceExists() {
            brokerLog.info("another broker holds \(HMProtocol.brokerLabel, privacy: .public); not registering ours")
            return .otherBroker
        }
        do {
            try service.register()
        } catch {
            // Approval pending also surfaces as an error on some systems: trust the status.
            if service.status == .requiresApproval { return .requiresApproval }
            brokerLog.error("registering the broker agent failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .failed("macOS didn't enable it")
        }
    }

    // MARK: Probes

    /// Whether launchd knows the lookup service, i.e. some job holds the broker label.
    /// Only an invalid connection means nobody does; a reply, an interruption, or no
    /// answer in time all mean a job owns the name. Blocks up to `timeout`.
    static func lookupServiceExists(timeout: TimeInterval = 2) -> Bool {
        let q = DispatchQueue(label: "dev.gavrix.hyprmux.broker-ping")
        let conn = xpc_connection_create_mach_service(HMProtocol.lookupService, q, 0)
        xpc_connection_set_event_handler(conn) { _ in }
        xpc_connection_resume(conn)
        defer { xpc_connection_cancel(conn) }
        let done = DispatchSemaphore(value: 0)
        var exists = true
        let message = xpcMessage(HMOp.lookup, ["instance": HMProtocol.currentInstance])
        xpc_connection_send_message_with_reply(conn, message, q) { reply in
            if reply === XPC_ERROR_CONNECTION_INVALID { exists = false }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { return true }
        return q.sync { exists }
    }

    /// What launchd runs under the broker label, from `launchctl print`. Nil when no job
    /// holds it. Blocks; call off the main thread.
    static func launchdJob() -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(HMProtocol.brokerLabel)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let job = LaunchdJob.parse(String(decoding: data, as: UTF8.self))
        // Only present values: an Optional stored as Any breaks JSONSerialization.
        var o: [String: Any] = [:]
        if let v = job.path { o["path"] = v }
        if let v = job.program { o["program"] = v }
        if let v = job.state { o["state"] = v }
        if let v = job.pid {
            o["pid"] = v
            // The running broker's absolute path tells which bundle it came from.
            var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(Int32(v), &buf, UInt32(buf.count)) > 0 { o["executable"] = String(cString: buf) }
        }
        if let v = job.parentBundle { o["parentBundle"] = v }
        if let v = job.origin(home: NSHomeDirectory()) { o["loadedBy"] = v.rawValue }
        return o
    }

    static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not-registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires-approval"
        case .notFound: return "not-found"
        @unknown default: return "unknown"
        }
    }
}
