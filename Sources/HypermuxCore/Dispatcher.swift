import Foundation

public enum WorkspaceTarget: Equatable, Sendable {
    case id(Int)
    case relative(Int)          // +1 / -1: by number, creating as needed
    case relativeExisting(Int)  // e+1 / e-1: among non-empty workspaces
    case previous
    case empty                  // first empty workspace
    case special(String)        // special[:name]
    case named(String)          // name:NAME, created on the first empty number if new

    public init?(hyprland raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(s), !s.hasPrefix("+"), !s.hasPrefix("-") {
            self = .id(n)
        } else if s.hasPrefix("+") || s.hasPrefix("-"), let n = Int(s) {
            self = .relative(n)
        } else if s.hasPrefix("e"), let n = Int(s.dropFirst()) {
            self = .relativeExisting(n)
        } else if s == "previous" {
            self = .previous
        } else if s == "empty" {
            self = .empty
        } else if s == "special" {
            self = .special("special")
        } else if s.hasPrefix("special:") {
            self = .special(String(s.dropFirst("special:".count)))
        } else if s.hasPrefix("name:") {
            let name = s.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = .named(name)
        } else {
            return nil
        }
    }
}

/// Navigation actions for web surfaces (`webnav, back`).
public enum WebNav: String, Equatable, Sendable, CaseIterable {
    case back, forward, reload, stop, home
    /// Put the cursor in the address bar.
    case focusurl
    /// Open Web Inspector.
    case inspect
}

/// Hypermux's own pickers, opened with `picker, KIND`. No Hyprland equivalent.
public enum PickerKind: String, Equatable, Sendable, CaseIterable {
    /// Go to a workspace: pick one, or type a number or a new name.
    case workspace
    /// Move the focused window to a workspace, and follow it.
    case moveToWorkspace = "movetoworkspace"
    /// Move the focused window to a workspace, and stay.
    case moveToWorkspaceSilent = "movetoworkspacesilent"
    /// Name the active workspace.
    case renameWorkspace = "renameworkspace"
}

public enum FullscreenMode: Int, Equatable, Sendable {
    /// Cover the whole monitor, no gaps or borders.
    case fullscreen = 0
    /// Fill the work area but keep outer gaps and the border.
    case maximize = 1
}

/// Hyprland-style dispatchers. The same names work in `bind =` lines and IPC.
public enum Dispatcher: Equatable, Sendable {
    case exec(String)
    /// Open a web surface (empty = home page, address bar focused).
    case web(String)
    case webNav(WebNav)
    /// Show an iOS Simulator's screen in a tile: UDID, device name, or "booted".
    case sim(String)
    /// Press a simulator hardware button: home, lock.
    case simButton(String)
    case killActive
    case moveFocus(Direction)
    case moveWindow(Direction)
    case swapWindow(Direction)
    case resizeActive(dx: Double, dy: Double)
    case moveActive(dx: Double, dy: Double)
    case workspace(WorkspaceTarget)
    case moveToWorkspace(WorkspaceTarget, silent: Bool)
    case toggleSpecialWorkspace(String)
    case toggleFloating
    case fullscreen(FullscreenMode)
    case toggleSplit
    case swapSplit
    case splitRatio(Double, exact: Bool)
    case cycleNext(previous: Bool)
    case focusCurrentOrLast
    case centerWindow
    case submap(String)
    /// Name a regular workspace. An empty name clears it (back to its workspace-rule name, if any).
    case renameWorkspace(Int, String)
    case picker(PickerKind)
    /// Toggle the monitor window between windowed and full screen (see misc:fullscreen_style).
    case monitorFullscreen
    // Groups (tabbed windows), Hyprland names.
    case toggleGroup
    case changeGroupActive(GroupStep)
    case moveIntoGroup(Direction)
    case moveOutOfGroup
    case moveGroupWindow(forward: Bool)
    case reload
    case exit

    public static func parse(_ name: String, _ args: String) -> Result<Dispatcher, ParseError> {
        let a = args.trimmingCharacters(in: .whitespaces)
        func needDirection(_ make: (Direction) -> Dispatcher) -> Result<Dispatcher, ParseError> {
            guard let d = Direction(hyprland: a) else { return .failure(.init("\(name): bad direction '\(a)'")) }
            return .success(make(d))
        }
        func needWorkspace(_ make: (WorkspaceTarget) -> Dispatcher) -> Result<Dispatcher, ParseError> {
            guard let w = WorkspaceTarget(hyprland: a) else { return .failure(.init("\(name): bad workspace '\(a)'")) }
            return .success(make(w))
        }
        func pair() -> (Double, Double)? {
            let parts = a.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return (x, y)
        }

        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "exec": return .success(.exec(a))
        case "web", "openurl": return .success(.web(a))
        case "sim", "simulator": return .success(.sim(a))
        case "simbutton":
            guard ["home", "lock"].contains(a.lowercased()) else { return .failure(.init("simbutton: expected home or lock")) }
            return .success(.simButton(a.lowercased()))
        case "webnav":
            guard let n = WebNav(rawValue: a.lowercased()) else {
                return .failure(.init("webnav: expected one of \(WebNav.allCases.map(\.rawValue).joined(separator: ", "))"))
            }
            return .success(.webNav(n))
        case "killactive", "kill": return .success(.killActive)
        case "movefocus": return needDirection { .moveFocus($0) }
        case "movewindow": return needDirection { .moveWindow($0) }
        case "swapwindow": return needDirection { .swapWindow($0) }
        case "resizeactive":
            guard let (x, y) = pair() else { return .failure(.init("resizeactive: expected 'dx dy'")) }
            return .success(.resizeActive(dx: x, dy: y))
        case "moveactive":
            guard let (x, y) = pair() else { return .failure(.init("moveactive: expected 'dx dy'")) }
            return .success(.moveActive(dx: x, dy: y))
        case "workspace": return needWorkspace { .workspace($0) }
        case "movetoworkspace": return needWorkspace { .moveToWorkspace($0, silent: false) }
        case "movetoworkspacesilent": return needWorkspace { .moveToWorkspace($0, silent: true) }
        case "togglespecialworkspace": return .success(.toggleSpecialWorkspace(a.isEmpty ? "special" : a))
        case "togglefloating": return .success(.toggleFloating)
        case "fullscreen":
            return .success(.fullscreen(a == "1" ? .maximize : .fullscreen))
        case "togglesplit": return .success(.toggleSplit)
        case "swapsplit": return .success(.swapSplit)
        case "splitratio":
            let parts = a.split(separator: " ").map(String.init)
            if parts.count == 2, parts[0] == "exact", let v = Double(parts[1]) {
                return .success(.splitRatio(v, exact: true))
            }
            guard let v = Double(a) else { return .failure(.init("splitratio: bad value '\(a)'")) }
            return .success(.splitRatio(v, exact: false))
        case "cyclenext": return .success(.cycleNext(previous: a == "prev"))
        case "focuscurrentorlast": return .success(.focusCurrentOrLast)
        case "centerwindow": return .success(.centerWindow)
        case "submap": return .success(.submap(a.isEmpty ? "reset" : a))
        case "renameworkspace":
            // Hyprland: "renameworkspace, 2 work".
            let parts = a.split(separator: " ", maxSplits: 1).map(String.init)
            guard let first = parts.first, let n = Int(first), n >= 1 else {
                return .failure(.init("renameworkspace: expected 'ID [name]'"))
            }
            return .success(.renameWorkspace(n, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""))
        case "picker":
            guard let k = PickerKind(rawValue: a.lowercased()) else {
                return .failure(.init("picker: expected one of \(PickerKind.allCases.map(\.rawValue).joined(separator: ", "))"))
            }
            return .success(.picker(k))
        case "monitorfullscreen": return .success(.monitorFullscreen)
        case "togglegroup": return .success(.toggleGroup)
        case "changegroupactive":
            switch a.lowercased() {
            case "", "f", "forward", "next": return .success(.changeGroupActive(.next))
            case "b", "back", "prev", "previous": return .success(.changeGroupActive(.previous))
            default:
                guard let n = Int(a), n >= 1 else { return .failure(.init("changegroupactive: expected f, b or a tab number")) }
                return .success(.changeGroupActive(.index(n)))
            }
        case "moveintogroup": return needDirection { .moveIntoGroup($0) }
        case "moveoutofgroup": return .success(.moveOutOfGroup)
        case "movegroupwindow":
            return .success(.moveGroupWindow(forward: !["b", "back", "prev", "previous"].contains(a.lowercased())))
        case "reload", "forcerendererreload": return .success(.reload)
        case "exit": return .success(.exit)
        default: return .failure(.init("unknown dispatcher '\(name)'"))
        }
    }
}

public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
