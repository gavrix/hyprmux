import Foundation

/// The credential value a fill target accepts. Terminals only accept passwords.
public enum CredentialField: String, Codable, Equatable, Sendable {
    case username
    case password
}

/// One out-of-process credential provider manifest.
public struct CredentialProviderManifest: Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var exec: String
    public var args: [String]
    public var timeout: Int
    public var disabled: Bool

    public init(id: String, name: String = "", description: String = "", exec: String = "",
                args: [String] = [], timeout: Int = 300, disabled: Bool = false) {
        self.id = id
        self.name = name.isEmpty ? id : name
        self.description = description
        self.exec = exec
        self.args = args
        self.timeout = timeout
        self.disabled = disabled
    }

    private static let keys: Set<String> = ["id", "name", "description", "exec", "args", "timeout", "disabled"]

    public static func parse(_ data: Data) -> Result<Self, ParseError> {
        guard let object = try? JSONSerialization.jsonObject(with: data), let values = object as? [String: Any] else {
            return .failure(ParseError("not a JSON object"))
        }
        if let unknown = Set(values.keys).subtracting(keys).sorted().first {
            return .failure(ParseError("unknown key \"\(unknown)\""))
        }
        guard let id = values["id"] as? String, !id.isEmpty else {
            return .failure(ParseError("\"id\" is required"))
        }
        guard isValidIdentifier(id) else {
            return .failure(ParseError("\"id\" must start with a letter or digit and use letters, digits, . _ -"))
        }
        func isBool(_ value: Any) -> Bool { CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() }
        var manifest = Self(id: id)
        if let value = values["disabled"] {
            guard isBool(value), let disabled = value as? Bool else {
                return .failure(ParseError("\"disabled\" must be true or false"))
            }
            manifest.disabled = disabled
        }
        if let value = values["name"], !(value is String) {
            return .failure(ParseError("\"name\" must be a string"))
        }
        if let value = values["description"] {
            guard let description = value as? String else {
                return .failure(ParseError("\"description\" must be a string"))
            }
            manifest.description = description
        }
        if let value = values["args"] {
            guard let args = value as? [String] else {
                return .failure(ParseError("\"args\" must be an array of strings"))
            }
            manifest.args = args
        }
        if let value = values["timeout"] {
            guard !isBool(value), let timeout = value as? Int, timeout > 0 else {
                return .failure(ParseError("\"timeout\" must be a positive integer"))
            }
            manifest.timeout = timeout
        }
        // An id-only disabled manifest overrides an earlier provider.
        if manifest.disabled, values["exec"] == nil { return .success(manifest) }
        guard let name = values["name"] as? String, !name.isEmpty else {
            return .failure(ParseError("\"name\" is required"))
        }
        manifest.name = name
        guard let executable = values["exec"] as? String, !executable.isEmpty else {
            return .failure(ParseError("\"exec\" is required"))
        }
        manifest.exec = executable
        return .success(manifest)
    }

    public static func isValidIdentifier(_ id: String) -> Bool {
        // ASCII only, so ids stay safe in config files, dispatcher arguments, and paths.
        guard let first = id.unicodeScalars.first, first.isASCII,
              CharacterSet.alphanumerics.contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }
}

/// What a `list` request fills. Providers may use it to rank items; Hyprmux enforces every check.
public struct CredentialContext: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case web, terminal
    }

    public let kind: Kind
    /// Web only: the page origin and normalized host.
    public let origin: String?
    public let host: String?
    public let field: CredentialField
    /// Terminal only: the foreground program's name and the terminal title, as ranking hints.
    public let process: String?
    public let title: String?

    enum CodingKeys: String, CodingKey {
        case kind, origin, host, field, process, title
    }

    /// Longest terminal hint sent to a provider.
    public static let maxHintLength = 256

    public init(origin: String, host: String, field: CredentialField) {
        kind = .web
        self.origin = origin
        self.host = host
        self.field = field
        process = nil
        title = nil
    }

    public static func terminal(process: String?, title: String?) -> Self {
        Self(kind: .terminal, origin: nil, host: nil, field: .password,
             process: hint(process), title: hint(title))
    }

    private init(kind: Kind, origin: String?, host: String?, field: CredentialField,
                 process: String?, title: String?) {
        self.kind = kind
        self.origin = origin
        self.host = host
        self.field = field
        self.process = process
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .web
        field = try c.decode(CredentialField.self, forKey: .field)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        process = try c.decodeIfPresent(String.self, forKey: .process)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        if kind == .web, origin == nil || host == nil {
            throw DecodingError.dataCorruptedError(forKey: .origin, in: c,
                                                   debugDescription: "a web context needs origin and host")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encode(field, forKey: .field)
        try c.encodeIfPresent(process, forKey: .process)
        try c.encodeIfPresent(title, forKey: .title)
    }

    private static func hint(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(maxHintLength))
    }
}

/// Why a terminal cannot receive a credential right now.
public enum TerminalCredentialRefusal: Equatable, Sendable {
    case notFocused, noPasswordPrompt, unknownProgram, programChanged

    public var message: String {
        switch self {
        case .notFocused: "Focus the terminal before filling a password."
        case .noPasswordPrompt: "This terminal is not showing a password prompt."
        case .unknownProgram: "Hyprmux could not identify the program asking for a password."
        case .programChanged: "The password prompt ended or another program took over the terminal."
        }
    }
}

/// The terminal facts that decide whether typing a password is safe.
public struct TerminalCredentialState: Equatable, Sendable {
    public var focused: Bool
    /// Ghostty's password-prompt heuristic: canonical input with echo off.
    public var passwordInput: Bool
    /// The terminal's foreground process group, or 0 when unknown.
    public var foregroundPID: Int32

    public init(focused: Bool, passwordInput: Bool, foregroundPID: Int32) {
        self.focused = focused
        self.passwordInput = passwordInput
        self.foregroundPID = foregroundPID
    }
}

public enum TerminalCredentialPolicy {
    /// Ghostty polls the PTY's termios every 200 ms, but only while the terminal is focused.
    /// After focus returns (the picker takes it), wait this long so the state is fresh.
    public static let settleInterval: Double = 0.3

    /// Checked when the dispatcher runs. Ghostty's state is only current while focused.
    public static func captureRefusal(_ state: TerminalCredentialState) -> TerminalCredentialRefusal? {
        guard state.focused else { return .notFocused }
        guard state.passwordInput else { return .noPasswordPrompt }
        guard state.foregroundPID > 0 else { return .unknownProgram }
        return nil
    }

    /// Checked immediately before typing. The same program must still be asking.
    public static func fillRefusal(capturedPID: Int32,
                                   _ state: TerminalCredentialState) -> TerminalCredentialRefusal? {
        guard state.focused else { return .notFocused }
        guard state.foregroundPID == capturedPID else { return .programChanged }
        guard state.passwordInput else { return .noPasswordPrompt }
        return nil
    }
}

/// One protocol-v1 request. Optional fields are omitted from encoded JSON.
public struct CredentialRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let op: String
    public let context: CredentialContext?
    public let id: String?
    public let field: CredentialField?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", op, context, id, field
    }

    public static func list(_ context: CredentialContext) -> Self {
        Self(protocolVersion: 1, op: "list", context: context, id: nil, field: nil)
    }

    public static func metadata(id: String) -> Self {
        Self(protocolVersion: 1, op: "metadata", context: nil, id: id, field: nil)
    }

    public static func reveal(id: String, field: CredentialField) -> Self {
        Self(protocolVersion: 1, op: "reveal", context: nil, id: id, field: field)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(op, forKey: .op)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(field, forKey: .field)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// Non-secret credential metadata. Providers must never include field values here.
public struct CredentialItemSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let account: String?
    public let websites: [String]
    public let container: String?
    public let containerLabel: String?

    public init(id: String, title: String, account: String? = nil, websites: [String] = [],
                container: String? = nil, containerLabel: String? = nil) {
        self.id = id
        self.title = title
        self.account = account
        self.websites = websites
        self.container = container
        self.containerLabel = containerLabel
    }

    /// Formats one stacked picker row. `pickerID` may namespace duplicate provider item IDs.
    public func pickerItem(pickerID: String? = nil, providerName: String? = nil,
                           includeProvider: Bool = false) -> PickerItem {
        let first = [title, nonempty(account)].compactMap { $0 }.joined(separator: " · ")
        var details: [String] = []
        if let website = websites.first.flatMap(CredentialSecurity.normalizeWebsiteHost) { details.append(website) }
        if let container = nonempty(container) {
            if let label = nonempty(containerLabel) { details.append("\(label): \(container)") }
            else { details.append(container) }
        }
        if includeProvider, let providerName = nonempty(providerName) { details.append(providerName) }
        return PickerItem(id: pickerID ?? id, title: first, detail: details.joined(separator: " · "))
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public enum CredentialErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case notInstalled, locked, unauthorized, notFound, unsupported, timeout, failed
}

/// Failure groups used to decide which multi-provider list errors should reach the user.
public enum CredentialListFailureKind: Equatable, Sendable {
    case notInstalled, locked, unauthorized, other
}

public enum CredentialFailurePolicy {
    /// Returns indices into `failures` that should be shown, preserving provider order.
    public static func visibleFailureIndices(_ failures: [CredentialListFailureKind],
                                             providerCount: Int,
                                             explicitProvider: Bool) -> [Int] {
        if explicitProvider || (!failures.isEmpty && failures.count == providerCount) {
            return Array(failures.indices)
        }
        return failures.indices.filter { failures[$0] != .notInstalled }
    }
}

/// The non-secret registry facts needed to resolve `credentials:providers`.
public struct CredentialProviderAvailability: Equatable, Sendable {
    public let id: String
    public let usable: Bool

    public init(id: String, usable: Bool) {
        self.id = id
        self.usable = usable
    }
}

public struct CredentialProviderOrderResolution: Equatable, Sendable {
    public let providerIDs: [String]
    public let skippedIDs: [String]

    public init(providerIDs: [String], skippedIDs: [String]) {
        self.providerIDs = providerIDs
        self.skippedIDs = skippedIDs
    }
}

public enum CredentialProviderOrdering {
    /// Nil means all usable providers sorted by id. A configured list is an ordered allowlist.
    public static func resolve(configuredIDs: [String]?,
                               available: [CredentialProviderAvailability]) -> CredentialProviderOrderResolution {
        guard let configuredIDs else {
            return .init(providerIDs: available.filter(\.usable).map(\.id).sorted(), skippedIDs: [])
        }
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0.usable) })
        var selected: [String] = []
        var skipped: [String] = []
        var seen = Set<String>()
        for id in configuredIDs where seen.insert(id).inserted {
            if byID[id] == true { selected.append(id) }
            else { skipped.append(id) }
        }
        return .init(providerIDs: selected, skippedIDs: skipped)
    }
}

public struct CredentialProtocolError: Error, Codable, Equatable, Sendable {
    public let code: CredentialErrorCode
    public let message: String

    public init(code: CredentialErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum CredentialResponse: Equatable, Sendable {
    case list([CredentialItemSummary])
    case metadata(CredentialItemSummary)
    case reveal(String)
    case error(CredentialProtocolError)

    public static func decode(_ data: Data) throws -> Self {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError("response is not a JSON object")
        }
        let recognized = ["items", "item", "value", "error"].filter { raw[$0] != nil }
        guard recognized.count == 1, raw.keys.allSatisfy({ recognized.contains($0) }) else {
            throw ParseError("response must contain exactly one result")
        }
        if let rows = raw["items"] as? [Any] {
            return .list(rows.compactMap(decodeItem))
        }
        if let row = raw["item"] as? [String: Any], let item = decodeItem(row) {
            return .metadata(item)
        }
        if let value = raw["value"] as? String { return .reveal(value) }
        if let error = raw["error"] as? [String: Any],
           let codeText = error["code"] as? String, let code = CredentialErrorCode(rawValue: codeText),
           let message = error["message"] as? String, !message.isEmpty,
           Set(error.keys).isSubset(of: ["code", "message"]) {
            return .error(CredentialProtocolError(code: code, message: message))
        }
        throw ParseError("malformed credential response")
    }

    private static func decodeItem(_ value: Any) -> CredentialItemSummary? {
        guard let row = value as? [String: Any],
              Set(row.keys).isSubset(of: ["id", "title", "account", "websites", "container", "containerLabel"]),
              let id = row["id"] as? String, CredentialSecurity.isValidItemID(id),
              let title = row["title"] as? String, !title.isEmpty else { return nil }
        func optionalString(_ key: String) -> String? {
            guard let value = row[key] else { return nil }
            return value as? String
        }
        if row["account"] != nil, row["account"] as? String == nil { return nil }
        if row["container"] != nil, row["container"] as? String == nil { return nil }
        if row["containerLabel"] != nil, row["containerLabel"] as? String == nil { return nil }
        let websites: [String]
        if let value = row["websites"] {
            guard let values = value as? [String] else { return nil }
            websites = values
        } else {
            websites = []
        }
        return CredentialItemSummary(id: id, title: title, account: optionalString("account"), websites: websites,
                                     container: optionalString("container"), containerLabel: optionalString("containerLabel"))
    }
}

public enum ChromiumCredentialPolicy {
    public static let unsafeDebuggingSwitches: Set<String> = [
        "remote-debugging-port", "remote-debugging-pipe", "devtools-protocol-log-file",
    ]

    /// Returns the configured switch that makes DOM credential filling unsafe.
    public static func refusingSwitch(in switches: [String]) -> String? {
        for raw in switches {
            var switchName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while switchName.hasPrefix("-") { switchName.removeFirst() }
            switchName = String(switchName.split(separator: "=", maxSplits: 1).first ?? "").lowercased()
            if unsafeDebuggingSwitches.contains(switchName) { return switchName }
        }
        return nil
    }
}

public enum CredentialSecurity {
    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`
    public static func isValidItemID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...128).contains(bytes.count), asciiAlphaNumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { asciiAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    private static func asciiAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// Normalizes an HTTP(S) URL, or a bare hostname, for comparison and display.
    public static func normalizeWebsiteHost(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        let colonCount = text.reduce(into: 0) { if $1 == ":" { $0 += 1 } }
        let candidate: String
        if text.contains("://") { candidate = text }
        else if colonCount >= 2, !text.hasPrefix("[") { candidate = "https://[\(text)]" }
        else { candidate = "https://" + text }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host.removeFirst(); host.removeLast() }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    public static func hostsMatch(pageHost: String, savedWebsites: [String]) -> Bool {
        guard let page = normalizeWebsiteHost(pageHost) else { return false }
        return savedWebsites.compactMap(normalizeWebsiteHost).contains(page)
    }

    public static func isAllowedCredentialOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || isIPv4Loopback(host)
    }

    public static func sameOrigin(_ url: URL, _ origin: String) -> Bool {
        guard let expected = URL(string: origin) else { return false }
        return url.scheme?.lowercased() == expected.scheme?.lowercased()
            && url.host?.lowercased() == expected.host?.lowercased()
            && effectivePort(url) == effectivePort(expected)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return octets.count == 4 && octets[0] == 127
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }
}
