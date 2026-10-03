import Foundation

/// How a key combination is written on screen: ⌃⌥⇧⌘ in Apple's order, then the key.
public enum KeyChord {
    public static func display(_ mods: Modifiers, _ trigger: BindTrigger) -> String {
        var s = ""
        if mods.contains(.ctrl) { s += "⌃" }
        if mods.contains(.alt) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.super) { s += "⌘" }
        switch trigger {
        case .key(let code): return s + keyName(code)
        case .mouse(let b): return s + (b == 272 ? "click" : b == 273 ? "right-click" : "mouse \(b)")
        }
    }

    static let symbols: [UInt16: String] = [
        0x24: "↩", 0x4C: "⌤", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x75: "⌦", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
    ]

    public static func keyName(_ code: UInt16) -> String {
        if let s = symbols[code] { return s }
        if let name = KeyCodes.table.first(where: { $0.value == code && $0.key.count == 1 })?.key { return name.uppercased() }
        if let name = KeyCodes.table.first(where: { $0.value == code && $0.key.hasPrefix("f") && $0.key.count <= 3 })?.key {
            return name.uppercased()
        }
        return "key \(code)"
    }
}

extension Dispatcher {
    /// A short name for what the dispatcher does, for the keycast.
    public var label: String {
        func dir(_ d: Direction) -> String {
            switch d { case .left: "left"; case .right: "right"; case .up: "up"; case .down: "down" }
        }
        func ws(_ t: WorkspaceTarget) -> String {
            switch t {
            case .id(let n): return "workspace \(n)"
            case .relative(let d): return d > 0 ? "next workspace" : "previous workspace"
            case .relativeExisting(let d): return d > 0 ? "next workspace" : "previous workspace"
            case .previous: return "last workspace"
            case .empty: return "an empty workspace"
            case .special(let s): return s == "special" ? "the scratchpad" : "scratchpad \(s)"
            case .named(let s): return s
            }
        }
        switch self {
        case .exec(let c): return c.isEmpty ? "New terminal" : "Run \(c)"
        case .web(let u): return u.isEmpty ? "New web tile" : "Open \(u)"
        case .webNav(let n):
            switch n {
            case .back: return "Back"
            case .forward: return "Forward"
            case .reload: return "Reload"
            case .stop: return "Stop"
            case .home: return "Home page"
            case .focusurl: return "Address bar"
            case .inspect: return "Web inspector"
            }
        case .fillCredential: return "Fill credential"
        case .sim(let q): return q.isEmpty ? "Show device" : "Show simulator \(q)"
        case .android(let q): return q.isEmpty ? "Show Android emulator" : "Show Android emulator \(q)"
        case .launch(let a): return a.isEmpty ? "Apps" : "Open \(a)"
        case .simButton(let b): return b == "lock" ? "Simulator lock" : "Simulator home"
        case .killActive: return "Close window"
        case .moveFocus(let d): return "Focus \(dir(d))"
        case .moveWindow(let d): return "Move window \(dir(d))"
        case .swapWindow(let d): return "Swap \(dir(d))"
        case .resizeActive: return "Resize"
        case .moveActive: return "Move window"
        case .workspace(let t):
            if case .id(let n) = t { return "Workspace \(n)" }
            return "Go to \(ws(t))"
        case .moveToWorkspace(let t, let silent): return (silent ? "Send to " : "Move to ") + ws(t)
        // "magic" is Hyprland's stock scratchpad name: not worth showing.
        case .toggleSpecialWorkspace(let s): return ["special", "magic"].contains(s) ? "Scratchpad" : "Scratchpad \(s)"
        case .toggleFloating: return "Float / tile"
        case .fullscreen(let m): return m == .maximize ? "Maximize" : "Fullscreen"
        case .toggleSplit: return "Flip split"
        case .swapSplit: return "Swap split"
        case .splitRatio: return "Split ratio"
        case .cycleNext(let prev): return prev ? "Previous window" : "Next window"
        case .focusCurrentOrLast: return "Last window"
        case .centerWindow: return "Center window"
        case .submap(let s): return s == "reset" ? "Leave mode" : s.prefix(1).uppercased() + s.dropFirst() + " mode"
        case .renameWorkspace: return "Name workspace"
        case .picker(let k):
            switch k {
            case .workspace: return "Go to workspace"
            case .moveToWorkspace: return "Move to workspace"
            case .moveToWorkspaceSilent: return "Send to workspace"
            case .renameWorkspace: return "Name workspace"
            case .layout: return "Layouts"
            case .saveLayout: return "Save layout"
            case .apps: return "Apps"
            }
        case .monitorFullscreen: return "Full-screen Hyprmux"
        case .toggleGroup: return "Group"
        case .changeGroupActive(let step):
            switch step {
            case .next: return "Next tab"
            case .previous: return "Previous tab"
            case .index(let n): return "Tab \(n)"
            }
        case .moveIntoGroup(let d): return "Into group \(dir(d))"
        case .moveOutOfGroup: return "Out of group"
        case .moveGroupWindow(let fwd): return fwd ? "Move tab forward" : "Move tab back"
        case .reload: return "Reload config"
        case .exit: return "Quit"
        }
    }
}

/// What the keycast shows: the last shortcut, counting quick repeats ("⌃⌘L Resize ×3").
public struct KeycastState: Equatable, Sendable {
    public private(set) var chord = ""
    public private(set) var label = ""
    public private(set) var count = 0
    private var last: Double = -.infinity
    /// A repeat within this many seconds counts up instead of starting over.
    public static let repeatWindow = 1.2

    public init() {}

    public mutating func press(chord: String, label: String, now: Double) {
        if chord == self.chord, label == self.label, now - last <= Self.repeatWindow {
            count += 1
        } else {
            self.chord = chord
            self.label = label
            count = 1
        }
        last = now
    }
}
