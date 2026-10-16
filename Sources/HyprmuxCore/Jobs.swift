import Foundation

/// Background jobs (`hyprmuxctl run`): one record per attached terminal's command, kept
/// after its terminal closes so `jobs wait` and `jobs log` still answer for it.
public struct JobRecord: Equatable, Sendable {
    public let id: ClientID
    public let parent: ClientID
    public let title: String
    /// The command's output, as the terminal got it (`hyprmuxctl run` writes it).
    public let log: String?
    public let started: Date
    public var ended: Date?
    public var exitStatus: Int?
    /// When the terminal closed. Before the command ended, that stopped it.
    public var closed: Date?

    public init(id: ClientID, parent: ClientID, title: String, log: String?, started: Date) {
        self.id = id
        self.parent = parent
        self.title = title
        self.log = log
        self.started = started
    }

    /// running, done (exit 0), failed, or stopped (closed while it ran).
    public var state: String {
        if let code = exitStatus { return code == 0 ? "done" : "failed" }
        return closed == nil ? "running" : "stopped"
    }

    public var isRunning: Bool { state == "running" }
}

/// Every job this run of Hyprmux started. Closed ones are kept, up to `keepClosed`.
public struct JobBook: Sendable {
    public private(set) var records: [ClientID: JobRecord] = [:]
    public var keepClosed = 100

    public init() {}

    public mutating func started(_ r: JobRecord) { records[r.id] = r }

    public mutating func exited(_ id: ClientID, status: Int, at: Date = Date()) {
        guard records[id]?.exitStatus == nil, records[id]?.closed == nil else { return }
        records[id]?.exitStatus = status
        records[id]?.ended = at
    }

    public mutating func closed(_ id: ClientID, at: Date = Date()) {
        guard records[id] != nil, records[id]?.closed == nil else { return }
        records[id]?.closed = at
        if records[id]?.ended == nil { records[id]?.ended = at }
        let closed = records.values.filter { $0.closed != nil }.sorted { $0.closed! < $1.closed! }
        for r in closed.dropLast(keepClosed) { records[r.id] = nil }
    }

    /// Oldest first. With a parent, only that tile's jobs.
    public func list(parent: ClientID? = nil) -> [JobRecord] {
        records.values.filter { parent == nil || $0.parent == parent }.sorted { $0.id < $1.id }
    }
}
