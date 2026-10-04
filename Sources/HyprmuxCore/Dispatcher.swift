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

/// Hyprmux's own pickers, opened with `picker, KIND`. No Hyprland equivalent.
public enum PickerKind: String, Equatable, Sendable, CaseIterable {
    /// Go to a workspace: pick one, or type a number or a new name.
    case workspace
    /// Move the focused window to a workspace, and follow it.
    case moveToWorkspace = "movetoworkspace"
    /// Move the focused window to a workspace, and stay.
    case moveToWorkspaceSilent = "movetoworkspacesilent"
    /// Name the active workspace.
    case renameWorkspace = "renameworkspace"
    /// Open a layout (a workspace template) from the layouts folder.
    case layout
    /// Save the active workspace as a layout.
    case saveLayout = "savelayout"
    /// The launcher: every app Hyprmux can open (docs/APPS.md).
    case apps
    /// The menu: one list that opens every other picker and a few actions.
    case menu
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
    /// Fill the focused credential input. Nil selects every enabled provider.
    case fillCredential(String?)
    /// Show an iOS Simulator's screen in a tile: UDID, device name, or "booted".
    case sim(String)
    /// Attach to a running Android Virtual Device: stable AVD id or name.
    case android(String)
    /// Press a simulator hardware button: home, lock.
    case simButton(String)
    /// Open an app from the catalog in a new tile: its name or id, then arguments.
    /// Empty opens the launcher.
    case launch(String)
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
        case "fillcredential":
            guard a.isEmpty || CredentialProviderManifest.isValidIdentifier(a) else {
                return .failure(.init("fillcredential: expected an optional provider id"))
            }
            return .success(.fillCredential(a.isEmpty ? nil : a))
        case "sim", "simulator": return .success(.sim(a))
        case "android", "avd": return .success(.android(a))
        case "launch": return .success(.launch(a))
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

extension Dispatcher {
    /// Whether the dispatcher acts on one window. A bind applies it to the focused window;
    /// IPC can name another one (`dispatch --surface N ...`). The rest act on the app or a workspace.
    public var targetsWindow: Bool {
        switch self {
        case .webNav, .fillCredential, .simButton, .killActive, .moveFocus, .moveWindow, .swapWindow,
             .resizeActive, .moveActive, .moveToWorkspace, .toggleFloating, .fullscreen,
             .toggleSplit, .swapSplit, .splitRatio, .cycleNext, .centerWindow,
             .toggleGroup, .changeGroupActive, .moveIntoGroup, .moveOutOfGroup, .moveGroupWindow:
            return true
        case .exec, .web, .sim, .android, .launch, .workspace, .toggleSpecialWorkspace, .focusCurrentOrLast,
             .submap, .renameWorkspace, .picker, .monitorFullscreen, .reload, .exit:
            return false
        }
    }
}

public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

extension Dispatcher {
    /// The dispatcher as a bind line writes it: a name and its arguments, so that
    /// `Dispatcher.parse(name, args)` gives it back. Events report dispatches this way.
    public var command: (name: String, args: String) {
        func dir(_ d: Direction) -> String {
            switch d { case .left: "l"; case .right: "r"; case .up: "u"; case .down: "d" }
        }
        func ws(_ t: WorkspaceTarget) -> String {
            switch t {
            case .id(let n): return "\(n)"
            case .relative(let d): return d > 0 ? "+\(d)" : "\(d)"
            case .relativeExisting(let d): return d > 0 ? "e+\(d)" : "e\(d)"
            case .previous: return "previous"
            case .empty: return "empty"
            case .special(let s): return s == "special" ? "special" : "special:\(s)"
            case .named(let s): return "name:\(s)"
            }
        }
        func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        switch self {
        case .exec(let c): return ("exec", c)
        case .web(let u): return ("web", u)
        case .webNav(let n): return ("webnav", n.rawValue)
        case .fillCredential(let p): return ("fillcredential", p ?? "")
        case .sim(let q): return ("sim", q)
        case .android(let q): return ("android", q)
        case .simButton(let b): return ("simbutton", b)
        case .launch(let a): return ("launch", a)
        case .killActive: return ("killactive", "")
        case .moveFocus(let d): return ("movefocus", dir(d))
        case .moveWindow(let d): return ("movewindow", dir(d))
        case .swapWindow(let d): return ("swapwindow", dir(d))
        case .resizeActive(let dx, let dy): return ("resizeactive", "\(num(dx)) \(num(dy))")
        case .moveActive(let dx, let dy): return ("moveactive", "\(num(dx)) \(num(dy))")
        case .workspace(let t): return ("workspace", ws(t))
        case .moveToWorkspace(let t, let silent): return (silent ? "movetoworkspacesilent" : "movetoworkspace", ws(t))
        case .toggleSpecialWorkspace(let s): return ("togglespecialworkspace", s == "special" ? "" : s)
        case .toggleFloating: return ("togglefloating", "")
        case .fullscreen(let m): return ("fullscreen", m == .maximize ? "1" : "0")
        case .toggleSplit: return ("togglesplit", "")
        case .swapSplit: return ("swapsplit", "")
        case .splitRatio(let v, let exact): return ("splitratio", exact ? "exact \(num(v))" : num(v))
        case .cycleNext(let prev): return ("cyclenext", prev ? "prev" : "")
        case .focusCurrentOrLast: return ("focuscurrentorlast", "")
        case .centerWindow: return ("centerwindow", "")
        case .submap(let s): return ("submap", s)
        case .renameWorkspace(let n, let name): return ("renameworkspace", name.isEmpty ? "\(n)" : "\(n) \(name)")
        case .picker(let k): return ("picker", k.rawValue)
        case .monitorFullscreen: return ("monitorfullscreen", "")
        case .toggleGroup: return ("togglegroup", "")
        case .changeGroupActive(let step):
            switch step {
            case .next: return ("changegroupactive", "f")
            case .previous: return ("changegroupactive", "b")
            case .index(let n): return ("changegroupactive", "\(n)")
            }
        case .moveIntoGroup(let d): return ("moveintogroup", dir(d))
        case .moveOutOfGroup: return ("moveoutofgroup", "")
        case .moveGroupWindow(let fwd): return ("movegroupwindow", fwd ? "f" : "b")
        case .reload: return ("reload", "")
        case .exit: return ("exit", "")
        }
    }
}
