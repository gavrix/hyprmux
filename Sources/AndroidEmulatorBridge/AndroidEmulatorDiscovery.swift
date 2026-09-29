import Darwin
import Foundation

/// A local Android Virtual Device (AVD) advertised by a running emulator process.
/// The bearer token stays private so logs and generic string interpolation cannot reveal it.
public struct AndroidEmulatorEndpoint: Equatable, Sendable, CustomStringConvertible {
    public let avdID: String
    public let name: String
    public let pid: Int32
    public let host: String
    public let port: Int
    public let emulatorVersion: String?
    let bearerToken: String?

    init(
        avdID: String,
        name: String,
        pid: Int32,
        host: String,
        port: Int,
        emulatorVersion: String? = nil,
        bearerToken: String?
    ) {
        self.avdID = avdID
        self.name = name
        self.pid = pid
        self.host = host
        self.port = port
        self.emulatorVersion = emulatorVersion
        self.bearerToken = bearerToken
    }

    public var description: String {
        "AndroidEmulatorEndpoint(avdID: \(avdID), name: \(name), pid: \(pid), host: \(host), port: \(port), version: \(emulatorVersion ?? "unknown"), token: <redacted>)"
    }

    /// Emulator 37.2.3 contains the Apple-silicon shared-memory frame-writing fix.
    var supportsSharedMemoryScreenshots: Bool {
        guard let emulatorVersion else { return false }
        let components = emulatorVersion.split(separator: ".").prefix(3).compactMap { component in
            Int(component.prefix(while: \.isNumber))
        }
        guard components.count == 3 else { return false }
        return Array(components).lexicographicallyPrecedes([37, 2, 3]) == false
    }
}

public enum AndroidEmulatorDiscovery {
    /// Android Emulator's macOS advertisement directory. The temporary-directory
    /// fallback covers emulator builds configured to use the process temporary root.
    public static func runningDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [URL] {
        let relative = "avd/running"
        let urls = [
            homeDirectory.appendingPathComponent("Library/Caches/TemporaryItems/\(relative)", isDirectory: true),
            temporaryDirectory.appendingPathComponent(relative, isDirectory: true),
        ]
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Finds advertised emulators whose process is still alive. This never starts,
    /// boots, stops, or otherwise changes an AVD.
    public static func running() -> [AndroidEmulatorEndpoint] {
        discover(in: runningDirectories(), isProcessRunning: processIsRunning)
    }

    static func discover(
        in directories: [URL],
        isProcessRunning: (Int32) -> Bool
    ) -> [AndroidEmulatorEndpoint] {
        let fm = FileManager.default
        var found: [Int32: AndroidEmulatorEndpoint] = [:]

        for directory in directories {
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let pid = pid(from: file.lastPathComponent), found[pid] == nil,
                      isProcessRunning(pid), let values = parseAdvertisement(file),
                      let endpoint = endpoint(values: values, pid: pid) else { continue }
                found[pid] = endpoint
            }
        }

        return found.values.sorted {
            let names = $0.name.localizedCaseInsensitiveCompare($1.name)
            return names == .orderedSame ? $0.pid < $1.pid : names == .orderedAscending
        }
    }

    /// Resolves a stable AVD id or display name. Matching is case-insensitive.
    public static func match(_ query: String, in endpoints: [AndroidEmulatorEndpoint]) -> AndroidEmulatorEndpoint? {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return endpoints.count == 1 ? endpoints[0] : nil }
        let exact = endpoints.filter {
            $0.avdID.compare(wanted, options: .caseInsensitive) == .orderedSame
                || $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame
        }
        return exact.count == 1 ? exact[0] : nil
    }

    private static func pid(from filename: String) -> Int32? {
        let prefix = "pid_", suffix = ".ini"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        var raw = filename[filename.index(filename.startIndex, offsetBy: prefix.count)..<end]
        if raw.hasSuffix("_info") { raw = raw.dropLast("_info".count) }
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber), let pid = Int32(raw), pid > 0 else { return nil }
        return pid
    }

    private static func processIsRunning(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func parseAdvertisement(_ url: URL) -> [String: String]? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_size >= 0,
              info.st_size <= 65_536 else { return nil }

        var data = Data(count: Int(info.st_size))
        let readComplete = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = read(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard readComplete, let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = value
        }
        return values
    }

    private static func endpoint(values: [String: String], pid: Int32) -> AndroidEmulatorEndpoint? {
        let name = values["avd.name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let avdID = values["avd.id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
        let host = values["grpc.address"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "127.0.0.1"
        guard !name.isEmpty, !avdID.isEmpty,
              ["127.0.0.1", "::1", "localhost"].contains(host.lowercased()),
              let port = values["grpc.port"].flatMap(Int.init), (1...65_535).contains(port) else { return nil }
        let token = values["grpc.token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AndroidEmulatorEndpoint(
            avdID: avdID,
            name: name,
            pid: pid,
            host: host,
            port: port,
            emulatorVersion: values["emulator.version"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            bearerToken: token?.isEmpty == false ? token : nil
        )
    }
}
