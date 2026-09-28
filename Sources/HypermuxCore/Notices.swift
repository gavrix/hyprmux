import Foundation

public enum NoticeLevel: String, CaseIterable, Sendable {
    case info, success, warning, error
}

/// One HUD notification.
public struct Notice: Equatable, Sendable {
    public typealias ID = UInt64

    /// Assigned by `NoticeQueue.post`.
    public internal(set) var id: ID = 0
    public var level: NoticeLevel
    public var title: String
    public var body: String
    /// Seconds on screen. Nil keeps it until it's dismissed.
    public var timeout: Double?
    /// Posting again with the same key updates this notice in place (config errors, progress).
    public var key: String?
    /// The client that raised it (a terminal's OSC 9). Clicking the notice focuses it.
    public var source: ClientID?
    /// How many identical posts this notice stands for, shown as "×3".
    public internal(set) var count = 1
    /// When it expires, in the queue's clock. Nil while sticky or held.
    public internal(set) var expires: Double?
    /// Time left when the pointer started holding it open.
    var heldRemaining: Double?

    public init(level: NoticeLevel = .info, title: String = "", body: String,
                timeout: Double? = 5, key: String? = nil, source: ClientID? = nil) {
        self.level = level
        self.title = title
        self.body = body
        self.timeout = timeout
        self.key = key
        self.source = source
    }

    func sameContent(as o: Notice) -> Bool {
        level == o.level && title == o.title && body == o.body && source == o.source
    }
}

/// Notification state: ordering, expiry, duplicates, and the visible limit.
/// Time comes in as a parameter so tests can drive it.
public struct NoticeQueue: Sendable {
    /// Newest first.
    public private(set) var notices: [Notice] = []
    /// Most notices on screen. Posting past it drops the oldest (timed ones first).
    public var maxVisible: Int {
        didSet { trim() }
    }
    private var nextID: Notice.ID = 1

    public init(maxVisible: Int = 5) {
        self.maxVisible = max(1, maxVisible)
    }

    public func notice(_ id: Notice.ID) -> Notice? { notices.first { $0.id == id } }

    /// Adds a notice, or refreshes an existing one with the same key or the same content.
    /// Returns the id it lives under.
    @discardableResult
    public mutating func post(_ n: Notice, now: Double) -> Notice.ID {
        if let key = n.key, let i = notices.firstIndex(where: { $0.key == key }) {
            var updated = n
            updated.id = notices[i].id
            updated.expires = n.timeout.map { now + $0 }
            notices[i] = updated
            return updated.id
        }
        if let i = notices.firstIndex(where: { $0.key == nil && $0.sameContent(as: n) }) {
            notices[i].count += 1
            notices[i].timeout = n.timeout
            if notices[i].heldRemaining != nil {
                notices[i].heldRemaining = n.timeout
            } else {
                notices[i].expires = n.timeout.map { now + $0 }
            }
            return notices[i].id
        }
        var new = n
        new.id = nextID
        nextID += 1
        new.expires = n.timeout.map { now + $0 }
        notices.insert(new, at: 0)
        trim()
        return new.id
    }

    @discardableResult
    public mutating func dismiss(_ id: Notice.ID) -> Bool {
        guard let i = notices.firstIndex(where: { $0.id == id }) else { return false }
        notices.remove(at: i)
        return true
    }

    @discardableResult
    public mutating func dismiss(key: String) -> Bool {
        guard let n = notices.first(where: { $0.key == key }) else { return false }
        return dismiss(n.id)
    }

    public mutating func dismissAll() { notices.removeAll() }

    /// Removes notices whose time is up. Returns their ids.
    @discardableResult
    public mutating func expire(now: Double) -> [Notice.ID] {
        let gone = notices.filter { ($0.expires ?? .infinity) <= now }.map(\.id)
        notices.removeAll { gone.contains($0.id) }
        return gone
    }

    /// The earliest expiry, for scheduling the next `expire` call.
    public var nextDeadline: Double? { notices.compactMap(\.expires).min() }

    /// Keeps a notice open while the pointer is over it.
    public mutating func hold(_ id: Notice.ID, now: Double) {
        guard let i = notices.firstIndex(where: { $0.id == id }), let e = notices[i].expires else { return }
        notices[i].heldRemaining = max(0, e - now)
        notices[i].expires = nil
    }

    /// Restarts the clock after `hold`, with at least `minimum` seconds left so it doesn't vanish instantly.
    public mutating func release(_ id: Notice.ID, now: Double, minimum: Double = 1.5) {
        guard let i = notices.firstIndex(where: { $0.id == id }), let left = notices[i].heldRemaining else { return }
        notices[i].heldRemaining = nil
        notices[i].expires = now + max(left, minimum)
    }

    private mutating func trim() {
        while notices.count > maxVisible {
            // Oldest timed notice first; sticky ones (config errors) go last.
            if let i = notices.lastIndex(where: { $0.timeout != nil }) {
                notices.remove(at: i)
            } else {
                notices.removeLast()
            }
        }
    }
}
