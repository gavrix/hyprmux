import Darwin
import Foundation
import HyprmuxCore

public enum OnePasswordProviderFailure: Error, Equatable {
    case protocolError(CredentialErrorCode, String)
    case commandFailed(String)
    case malformedData(String)

    public var response: CredentialProtocolError {
        switch self {
        case .protocolError(let code, let message): return .init(code: code, message: message)
        case .commandFailed(let stderr):
            let text = stderr.lowercased()
            if text.contains("not signed in") || text.contains("sign in") {
                return .init(code: .unauthorized, message: "Sign in to 1Password and try again.")
            }
            if text.contains("locked") || text.contains("unlock") || text.contains("authorization") {
                return .init(code: .locked, message: "Unlock 1Password and try again.")
            }
            if text.contains("isn't an item") || text.contains("not found") || text.contains("could not find") {
                return .init(code: .notFound, message: "The selected 1Password item no longer exists.")
            }
            return .init(code: .failed, message: "1Password did not complete the request. Unlock the app and try again.")
        case .malformedData(let operation):
            return .init(code: .failed, message: "1Password returned unreadable data for \(operation).")
        }
    }
}

public final class OnePasswordSignalForwarder {
    private let lock = NSLock()
    private var process: Process?
    private var sources: [DispatchSourceSignal] = []

    public init() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.received(signalNumber) }
            source.resume()
            sources.append(source)
        }
    }

    fileprivate func setRunningProcess(_ process: Process?) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    private func received(_ signalNumber: Int32) {
        lock.lock()
        let childPID = process?.isRunning == true ? process?.processIdentifier : nil
        lock.unlock()
        if let childPID { _ = kill(childPID, SIGTERM) }
        Darwin.exit(128 + signalNumber)
    }
}

public struct OnePasswordCredentialProvider {
    public static let executableLocations = ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
    public static let versionArguments = ["--version"]
    public static let listArguments = ["item", "list", "--categories", "Login", "--format=json"]

    public let executable: String
    private let signalForwarder: OnePasswordSignalForwarder?

    public init(executable: String, signalForwarder: OnePasswordSignalForwarder? = nil) {
        self.executable = executable
        self.signalForwarder = signalForwarder
    }

    public static func resolveExecutable(fileManager: FileManager = .default,
                                         signalForwarder: OnePasswordSignalForwarder? = nil) throws -> String {
        var found = false
        for path in executableLocations where fileManager.isExecutableFile(atPath: path) {
            found = true
            let provider = Self(executable: path, signalForwarder: signalForwarder)
            if (try? provider.checkVersion()) == true { return path }
        }
        if found {
            throw OnePasswordProviderFailure.protocolError(.unsupported, "1Password CLI version 2 is required.")
        }
        throw OnePasswordProviderFailure.protocolError(
            .notInstalled, "Install 1Password CLI version 2 at /opt/homebrew/bin/op or /usr/local/bin/op.")
    }

    public static func majorVersion(_ output: String) -> Int? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard let first = text.split(separator: ".", omittingEmptySubsequences: false).first,
              !first.isEmpty, first.allSatisfy(\.isNumber) else { return nil }
        return Int(first)
    }

    public func checkVersion() throws -> Bool {
        let result = try run(arguments: Self.versionArguments)
        guard result.status == 0, let text = String(data: result.stdout, encoding: .utf8) else { return false }
        return Self.majorVersion(text) == 2
    }

    public func list() throws -> [CredentialItemSummary] {
        let output = try checked(arguments: Self.listArguments)
        return try Self.decodeList(output)
    }

    public func metadata(id: String) throws -> CredentialItemSummary {
        guard CredentialSecurity.isValidItemID(id) else {
            throw OnePasswordProviderFailure.protocolError(.notFound, "The selected 1Password item is invalid.")
        }
        return try Self.decodeMetadata(checked(arguments: ["item", "get", id, "--format=json"]))
    }

    /// Reveals the whole item because `--fields` matches mutable labels and may return custom fields.
    /// The adapter selects the built-in purpose and emits only the requested value.
    public func reveal(id: String, field: CredentialField) throws -> String {
        guard CredentialSecurity.isValidItemID(id) else {
            throw OnePasswordProviderFailure.protocolError(.notFound, "The selected 1Password item is invalid.")
        }
        var data = try checked(arguments: ["item", "get", id, "--format=json", "--reveal"])
        defer { data.resetBytes(in: data.indices) }
        return try Self.decodeRevealedField(data, field: field)
    }

    public static func decodeList(_ data: Data) throws -> [CredentialItemSummary] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw OnePasswordProviderFailure.malformedData("the Login list")
        }
        return rows.compactMap { raw in
            guard let row = raw as? [String: Any], let id = row["id"] as? String,
                  CredentialSecurity.isValidItemID(id) else { return nil }
            if let category = row["category"] as? String,
               category.caseInsensitiveCompare("LOGIN") != .orderedSame { return nil }
            let vault = row["vault"] as? [String: Any]
            return CredentialItemSummary(
                id: id,
                title: nonempty(row["title"] as? String) ?? "Untitled Login",
                account: nonempty(row["additional_information"] as? String),
                websites: websites(in: row),
                container: nonempty(vault?["name"] as? String),
                containerLabel: nonempty(vault?["name"] as? String) == nil ? nil : "vault")
        }
    }

    public static func decodeMetadata(_ data: Data) throws -> CredentialItemSummary {
        let row = try itemRoot(data, operation: "item metadata")
        guard let id = row["id"] as? String, CredentialSecurity.isValidItemID(id) else {
            throw OnePasswordProviderFailure.malformedData("item metadata")
        }
        let vault = row["vault"] as? [String: Any]
        return CredentialItemSummary(
            id: id,
            title: nonempty(row["title"] as? String) ?? "Untitled Login",
            account: nonempty(row["additional_information"] as? String),
            websites: websites(in: row),
            container: nonempty(vault?["name"] as? String),
            containerLabel: nonempty(vault?["name"] as? String) == nil ? nil : "vault")
    }

    public static func decodeRevealedField(_ data: Data, field: CredentialField) throws -> String {
        let row = try itemRoot(data, operation: "the selected Login")
        let fields = (row["fields"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let purpose = field == .username ? "USERNAME" : "PASSWORD"
        let identifier = field.rawValue
        for candidate in fields where (candidate["purpose"] as? String)?.caseInsensitiveCompare(purpose) == .orderedSame {
            if let value = nonempty(candidate["value"] as? String) { return value }
        }
        for candidate in fields where (candidate["id"] as? String)?.caseInsensitiveCompare(identifier) == .orderedSame {
            if let value = nonempty(candidate["value"] as? String) { return value }
        }
        throw OnePasswordProviderFailure.protocolError(.notFound, "The selected 1Password Login has no \(field.rawValue).")
    }

    private static func itemRoot(_ data: Data, operation: String) throws -> [String: Any] {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnePasswordProviderFailure.malformedData(operation)
        }
        if let category = row["category"] as? String,
           category.caseInsensitiveCompare("LOGIN") != .orderedSame {
            throw OnePasswordProviderFailure.protocolError(.unsupported, "The selected 1Password item is not a Login.")
        }
        return row
    }

    private static func websites(in row: [String: Any]) -> [String] {
        let urls = (row["urls"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var values: [String] = []
        for url in urls.filter({ $0["primary"] as? Bool == true }) + urls.filter({ $0["primary"] as? Bool != true }) {
            guard let href = url["href"] as? String, CredentialSecurity.normalizeWebsiteHost(href) != nil,
                  !values.contains(href) else { continue }
            values.append(href)
        }
        return values
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func checked(arguments: [String]) throws -> Data {
        var output = try run(arguments: arguments)
        defer {
            output.stdout.resetBytes(in: output.stdout.indices)
            output.stderr.resetBytes(in: output.stderr.indices)
        }
        guard output.status == 0 else {
            throw OnePasswordProviderFailure.commandFailed(String(data: output.stderr, encoding: .utf8) ?? "")
        }
        return output.stdout
    }

    private func run(arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("OP_") { environment.removeValue(forKey: key) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let capture = AdapterCapture()
        let reads = DispatchGroup()
        for (index, handle) in [stdout.fileHandleForReading, stderr.fileHandleForReading].enumerated() {
            reads.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let data = handle.readData(ofLength: 64 * 1024)
                    guard !data.isEmpty else { break }
                    capture.append(data, index: index)
                }
                reads.leave()
            }
        }
        do {
            try process.run()
            signalForwarder?.setRunningProcess(process)
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
        } catch {
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            reads.wait()
            throw OnePasswordProviderFailure.protocolError(.failed, "1Password CLI could not start.")
        }
        process.waitUntilExit()
        signalForwarder?.setRunningProcess(nil)
        reads.wait()
        let values = capture.take()
        guard !values.exceeded else {
            throw OnePasswordProviderFailure.protocolError(.failed, "1Password returned too much data.")
        }
        return CommandOutput(status: process.terminationStatus, stdout: values.stdout, stderr: values.stderr)
    }
}

private struct CommandOutput {
    let status: Int32
    var stdout: Data
    var stderr: Data
}

private final class AdapterCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [Data(), Data()]
    private var exceeded = false
    private let limit = 16 * 1024 * 1024

    func append(_ data: Data, index: Int) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - values[index].count)
        if data.count > remaining { exceeded = true }
        if remaining > 0 { values[index].append(data.prefix(remaining)) }
    }

    func take() -> (stdout: Data, stderr: Data, exceeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (values[0], values[1], exceeded)
    }

    deinit {
        for index in values.indices { values[index].resetBytes(in: values[index].indices) }
    }
}
