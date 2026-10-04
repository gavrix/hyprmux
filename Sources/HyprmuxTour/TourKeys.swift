import Foundation
import HyprmuxCore

/// The user's real shortcuts, read from their config, so the tour never shows a key
/// that their config changed or removed.
public struct TourKeys: Sendable {
    public let binds: [KeyBind]

    public init(binds: [KeyBind]) {
        self.binds = binds.filter {
            if case .key = $0.trigger { return $0.submap == "reset" }
            return false
        }
    }

    public init(config: HyprmuxConfig) { self.init(binds: config.binds) }

    private func bind(_ match: (Dispatcher) -> Bool) -> KeyBind? { binds.first { match($0.dispatcher) } }

    /// The first bind whose dispatcher matches, written as a chord ("⌘↩").
    public func chord(_ match: (Dispatcher) -> Bool) -> String? {
        bind(match).map { Self.display($0.mods, $0.trigger) }
    }

    public func chord(_ d: Dispatcher) -> String? { chord { $0 == d } }

    /// Several binds written as one family when they share modifiers: "⌘H/J/K/L".
    /// Nil when any of them is unbound.
    public func family(_ ds: [Dispatcher]) -> String? {
        let found = ds.compactMap { d in bind { $0 == d } }
        guard found.count == ds.count, let first = found.first else { return nil }
        guard found.allSatisfy({ $0.mods == first.mods }) else {
            return found.map { Self.display($0.mods, $0.trigger) }.joined(separator: " ")
        }
        let prefix = String(Self.display(first.mods, first.trigger).dropLast(keyName(first).count))
        return prefix + found.map(keyName).joined(separator: "/")
    }

    private func keyName(_ b: KeyBind) -> String {
        if case .key(let code) = b.trigger { return Self.readable(KeyChord.keyName(code)) }
        return ""
    }

    /// The keycast's notation, with words for the symbols newcomers don't know (the README
    /// writes ⌃Tab too).
    static func display(_ mods: Modifiers, _ trigger: BindTrigger) -> String {
        readable(KeyChord.display(mods, trigger))
    }

    static func readable(_ s: String) -> String {
        s.replacingOccurrences(of: "⇥", with: "Tab").replacingOccurrences(of: "⎋", with: "Esc")
            .replacingOccurrences(of: "⌫", with: "Delete")
    }

    // MARK: The actions the tour teaches

    static let directions: [Direction] = [.left, .down, .up, .right]

    public var newTerminal: String? { chord(.exec("")) }
    public var close: String? { chord(.killActive) }
    public var focusAll: String? { family(Self.directions.map { .moveFocus($0) }) }
    public func focus(_ d: Direction) -> String? { chord(.moveFocus(d)) }
    public var moveAll: String? { family(Self.directions.map { .moveWindow($0) }) }
    public var swapAll: String? { family(Self.directions.map { .swapWindow($0) }) }
    public var last: String? { chord(.focusCurrentOrLast) }
    public var float: String? { chord(.toggleFloating) }
    public var maximize: String? { chord(.fullscreen(.maximize)) }
    public var fullscreen: String? { chord(.fullscreen(.fullscreen)) }
    public var web: String? { chord(.web("")) }
    public var addressBar: String? { chord(.webNav(.focusurl)) }
    public var group: String? { chord(.toggleGroup) }
    public var nextTab: String? { chord(.changeGroupActive(.next)) }
    public var workspacePicker: String? { chord(.picker(.workspace)) }
    public var renameWorkspace: String? { chord(.picker(.renameWorkspace)) }
    public var reload: String? { chord(.reload) }
    public var device: String? { chord { if case .sim = $0 { return true }; return false } }
    public var apps: String? { chord(.picker(.apps)) }
    public var layout: String? { chord(.picker(.layout)) }
    public var saveLayout: String? { chord(.picker(.saveLayout)) }

    public func workspace(_ n: Int) -> String? { chord(.workspace(.id(n))) }
    public func moveToWorkspace(_ n: Int) -> String? { chord(.moveToWorkspace(.id(n), silent: false)) }

    /// `togglespecialworkspace`, whatever the scratchpad is called.
    public var scratchpad: String? {
        chord { if case .toggleSpecialWorkspace = $0 { return true }; return false }
    }

    /// Resize with ⌃⌘H/L: the horizontal pair of `resizeactive` binds.
    public var resize: String? {
        let left = bind { if case .resizeActive(let dx, let dy) = $0 { return dx < 0 && dy == 0 }; return false }
        let right = bind { if case .resizeActive(let dx, let dy) = $0 { return dx > 0 && dy == 0 }; return false }
        guard let left, let right else { return nil }
        guard left.mods == right.mods else {
            return Self.display(left.mods, left.trigger) + " " + Self.display(right.mods, right.trigger)
        }
        let prefix = String(Self.display(left.mods, left.trigger).dropLast(keyName(left).count))
        return prefix + keyName(left) + "/" + keyName(right)
    }

    /// The bind that enters the resize submap ("⌘R").
    public var resizeMode: String? {
        chord { if case .submap(let s) = $0 { return s != "reset" }; return false }
    }
}
