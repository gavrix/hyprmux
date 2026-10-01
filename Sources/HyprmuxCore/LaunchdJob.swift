import Foundation

/// The fields of `launchctl print gui/UID/LABEL` that tell which program a job runs and
/// who loaded it. `hyprmuxctl broker status` shows them for the broker.
public struct LaunchdJob: Equatable, Sendable {
    public enum Origin: String, Sendable {
        /// `scripts/dev-broker.sh`: a plist copy under ~/Library/Caches/dev.gavrix.hyprmux/.
        case devBroker = "dev-broker.sh"
        /// An app registered it with SMAppService (`managed_by = com.apple.xpc.ServiceManagement`).
        case app
        case other
    }

    public var path: String?
    public var program: String?
    public var state: String?
    public var pid: Int?
    public var parentBundle: String?
    /// `com.apple.xpc.ServiceManagement` for agents an app registered.
    public var managedBy: String?

    /// Who loaded the job, from where its plist lives.
    public func origin(home: String) -> Origin? {
        if managedBy == "com.apple.xpc.ServiceManagement" { return .app }
        guard let path else { return nil }
        if path.hasPrefix(home + "/Library/Caches/dev.gavrix.hyprmux/") { return .devBroker }
        return .other
    }

    /// Reads the job's own fields: lines one tab deep, first occurrence wins (nested
    /// blocks repeat keys like `state`).
    public static func parse(_ text: String) -> LaunchdJob {
        var job = LaunchdJob()
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "path": job.path = job.path ?? value
            case "program": job.program = job.program ?? value
            // SMAppService jobs name the program relative to their app, with a mode suffix:
            // `program identifier = Contents/MacOS/hyprmux-broker (mode: 2)`.
            case "program identifier":
                let bare = value.range(of: " (mode:").map { String(value[..<$0.lowerBound]) } ?? value
                job.program = job.program ?? bare
            case "managed_by": job.managedBy = job.managedBy ?? value
            case "state": job.state = job.state ?? value
            case "pid": job.pid = job.pid ?? Int(value)
            case "parent bundle identifier": job.parentBundle = job.parentBundle ?? value
            default: break
            }
        }
        return job
    }
}
