import Darwin
import Foundation
import HyprmuxCore

public enum CredentialProcessError: Error, Equatable, Sendable {
    case launchFailed
    case untrustedExecutable(String)
    case timedOut
    case outputTooLarge
    case nonzeroExit
    case malformedResponse
    case provider(CredentialProtocolError)

    public var userMessage: String {
        switch self {
        case .launchFailed: "The credential provider could not start."
        case .untrustedExecutable(let problem): "The credential provider is no longer trusted. Its executable \(problem)."
        case .timedOut: "The credential provider timed out."
        case .outputTooLarge: "The credential provider returned too much data."
        case .nonzeroExit: "The credential provider failed."
        case .malformedResponse: "The credential provider returned an unreadable response."
        case .provider(let error): error.message
        }
    }
}

/// Runs one protocol request in a fresh provider process.
public enum CredentialProcess {
    public static let stdoutLimit = 16 * 1024 * 1024
    public static let stderrLimit = 1 * 1024 * 1024

    public static func request(_ request: CredentialRequest, provider: CredentialProviderEntry) throws -> CredentialResponse {
        guard let executable = provider.executable else { throw CredentialProcessError.launchFailed }
        if let problem = CredentialProviderRegistry.executableTrustProblem(executable, source: provider.source) {
            throw CredentialProcessError.untrustedExecutable(problem)
        }
        return try run(executable: executable, arguments: provider.manifest.args,
                       request: request, timeout: TimeInterval(provider.manifest.timeout))
    }

    /// Public for runner tests and third-party embedding. stderr is captured only to drain it.
    public static func run(executable: String, arguments: [String], request: CredentialRequest,
                           timeout: TimeInterval) throws -> CredentialResponse {
        var input: Data
        do { input = try request.encoded() }
        catch { throw CredentialProcessError.malformedResponse }
        defer { input.resetBytes(in: input.indices) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HYPRMUX_CREDENTIAL_PROTOCOL"] = "1"
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let capture = BoundedPipeCapture(limits: [stdoutLimit, stderrLimit])
        let readers = DispatchGroup()
        for (index, handle) in [stdout.fileHandleForReading, stderr.fileHandleForReading].enumerated() {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = handle.readData(ofLength: 64 * 1024)
                    guard !chunk.isEmpty else { break }
                    capture.append(chunk, at: index)
                }
                readers.leave()
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            stdin.fileHandleForWriting.closeFile()
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            readers.wait()
            throw CredentialProcessError.launchFailed
        }
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        let inputHandle = stdin.fileHandleForWriting
        // A provider may close stdin before Hyprmux writes. Suppress SIGPIPE and let the
        // throwing write report EPIPE without terminating the app.
        if fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 {
            try? inputHandle.write(contentsOf: input)
        }
        try? inputHandle.close()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            readers.wait()
            capture.clear()
            throw CredentialProcessError.timedOut
        }
        readers.wait()
        var output = capture.take(at: 0)
        let stderrExceeded = capture.exceeded(at: 1)
        capture.clear()
        defer { output.resetBytes(in: output.indices) }
        if capture.stdoutExceeded || stderrExceeded { throw CredentialProcessError.outputTooLarge }

        let decoded = try? CredentialResponse.decode(output)
        if let decoded, case .error(let error) = decoded { throw CredentialProcessError.provider(error) }
        guard process.terminationStatus == 0 else { throw CredentialProcessError.nonzeroExit }
        guard let decoded else { throw CredentialProcessError.malformedResponse }
        return decoded
    }
}

private final class BoundedPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: [Int]
    private var values = [Data(), Data()]
    private var didExceed = [false, false]
    private(set) var stdoutExceeded = false

    init(limits: [Int]) { self.limits = limits }

    func append(_ data: Data, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limits[index] - values[index].count)
        if data.count > remaining { didExceed[index] = true }
        if remaining > 0 { values[index].append(data.prefix(remaining)) }
    }

    func take(at index: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        let value = values[index]
        values[index] = Data()
        stdoutExceeded = didExceed[0]
        return value
    }

    func exceeded(at index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return didExceed[index]
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        for index in values.indices {
            values[index].resetBytes(in: values[index].indices)
            values[index] = Data()
            didExceed[index] = false
        }
    }

    deinit { clear() }
}
