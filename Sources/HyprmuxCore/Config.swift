import Foundation

public struct Color: Equatable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// rgba(33ccffee), rgba(51,204,255,0.9), rgb(33ccff), rgb(51,204,255), 0xAARRGGBB, #RRGGBB[AA].
    public static func parse(_ raw: String) -> Color? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        func hex(_ h: Substring, alphaLast: Bool) -> Color? {
            guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
            let n = Double.self
            if h.count == 6 {
                return Color(r: n.init((v >> 16) & 0xff) / 255, g: n.init((v >> 8) & 0xff) / 255, b: n.init(v & 0xff) / 255)
            }
            if alphaLast {
                return Color(r: n.init((v >> 24) & 0xff) / 255, g: n.init((v >> 16) & 0xff) / 255,
                             b: n.init((v >> 8) & 0xff) / 255, a: n.init(v & 0xff) / 255)
            }
            return Color(r: n.init((v >> 16) & 0xff) / 255, g: n.init((v >> 8) & 0xff) / 255,
                         b: n.init(v & 0xff) / 255, a: n.init((v >> 24) & 0xff) / 255)
        }
        if s.hasPrefix("0x") { return hex(s.dropFirst(2), alphaLast: false) }
        if s.hasPrefix("#") { return hex(s.dropFirst(), alphaLast: true) }
        for prefix in ["rgba(", "rgb("] where s.hasPrefix(prefix) && s.hasSuffix(")") {
            let inner = s.dropFirst(prefix.count).dropLast()
            if !inner.contains(",") { return hex(inner, alphaLast: true) }
            let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            return Color(r: parts[0] / 255, g: parts[1] / 255, b: parts[2] / 255, a: parts.count == 4 ? parts[3] : 1)
        }
        return nil
    }
}

/// A border color: one or more colors plus an angle, e.g. `rgba(33ccffee) rgba(00ff99ee) 45deg`.
public struct Gradient: Equatable, Sendable {
    public var colors: [Color]
    public var angle: Double
    public init(_ colors: [Color], angle: Double = 0) { self.colors = colors; self.angle = angle }

    public static func parse(_ raw: String) -> Gradient? {
        var tokens: [String] = []
        var cur = ""
        var depth = 0
        for ch in raw {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == " " && depth == 0 {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        var colors: [Color] = []
        var angle = 0.0
        for t in tokens {
            if t.hasSuffix("deg"), let a = Double(t.dropLast(3)) { angle = a; continue }
            guard let c = Color.parse(t) else { return nil }
            colors.append(c)
        }
        return colors.isEmpty ? nil : Gradient(colors, angle: angle)
    }
}

public struct AnimationSpec: Equatable, Sendable {
    public var enabled: Bool
    /// Hyprland units: 1 = 100 ms.
    public var speed: Double
    public var curve: String
    public var style: String?
    public init(enabled: Bool, speed: Double, curve: String, style: String? = nil) {
        self.enabled = enabled; self.speed = speed; self.curve = curve; self.style = style
    }
}

public struct ResolvedAnimation: Equatable, Sendable {
    public var enabled: Bool
    public var duration: Double  // seconds
    public var curve: Bezier
    public var style: String?
}

public struct KeyBind: Equatable, Sendable {
    public var mods: Modifiers
    public var trigger: BindTrigger
    public var dispatcher: Dispatcher
    /// Hyprland bind flags: e (repeat), l (locked), r (release), n (non-consuming), m (mouse).
    public var flags: Set<Character>
    public var submap: String
}

public struct HyprmuxConfig: Sendable {
    public var wm = WMSettings()
    public var activeBorder = Gradient([Color(r: 0.2, g: 0.8, b: 1, a: 0.93), Color(r: 0, g: 1, b: 0.6, a: 0.93)], angle: 45)
    public var inactiveBorder = Gradient([Color(r: 0.35, g: 0.35, b: 0.35, a: 0.67)])
    public var rounding: Double = 10
    /// Corner curve: 2 = circular, 4 = squircle, higher = squarer (Hyprland decoration:rounding_power).
    public var roundingPower: Double = 2
    public var activeOpacity: Double = 1
    public var inactiveOpacity: Double = 1
    public var dimInactive = false
    public var dimStrength: Double = 0.5
    public var dimSpecial: Double = 0.2
    public var shadowEnabled = true
    public var shadowRange: Double = 4
    public var shadowColor = Color(r: 0.1, g: 0.1, b: 0.1, a: 0.93)
    /// Blur whatever is behind each window (macOS behind-window blur).
    public var blurEnabled = false
    public var animationsEnabled = true
    public var beziers: [String: Bezier] = ["default": .hyprDefault, "linear": .linear]
    public var animations: [String: AnimationSpec] = [:]
    /// 0 = click to focus, 1 = focus follows mouse.
    public var followMouse = 1
    public var binds: [KeyBind] = []
    public var execOnce: [String] = []
    public var exec: [String] = []
    public var backgroundColor = Color(r: 0.07, g: 0.07, b: 0.1)
    /// "fill": cover the display on the normal desktop (wallpaper stays visible behind
    /// a transparent window). "native": macOS full screen on its own Space.
    public var fullscreenStyle = "fill"

    // Groups (tabbed windows).
    public var groupActiveBorder = Gradient([Color(r: 1, g: 0.67, b: 0.2, a: 0.93), Color(r: 1, g: 0.37, b: 0.37, a: 0.93)], angle: 45)
    public var groupInactiveBorder = Gradient([Color(r: 0.47, g: 0.33, b: 0.2, a: 0.67)])
    /// Border width for grouped windows; nil = general:border_size.
    public var groupBorderSize: Double?
    public var groupbarEnabled = true
    public var groupbarHeight: Double = 20
    public var groupbarFontSize: Double = 11
    public var groupbarActive = Color(r: 0.2, g: 0.8, b: 1, a: 0.93)
    public var groupbarInactive = Color(r: 0.23, g: 0.23, b: 0.29, a: 0.93)
    public var groupbarText = Color(r: 1, g: 1, b: 1, a: 0.93)
    /// Extra lines handed to libghostty's config (from a `ghostty { ... }` block).
    public var ghostty: [String] = []
    public var errors: [String] = []
    public var sourcePath: String?

    /// Hyprmux's own UI: notifications (and later menus and pickers).
    public var hud = HUDSettings()
    /// What a restart brings back.
    public var session = RestoreSettings()
    /// ⌘Q quits only when pressed twice, like Chrome's "Press ⌘Q again to quit".
    public var confirmQuit = true

    /// Web surfaces.
    public var webHome = "https://duckduckgo.com"
    /// Search URL for address-bar input that isn't a URL. `%s` = query.
    public var webSearch = "https://duckduckgo.com/?q=%s"
    /// Open http(s) links clicked in terminals (cmd+click) in a web surface.
    public var webOpenTerminalLinks = true
    public var webShowAddressBar = true
    /// "webkit" (light, no passkeys) or "chromium" (CEF; passkeys via phone or security key).
    public var webEngine = "webkit"
    /// Unpacked Chrome extensions (directories) to load into Chromium.
    public var chromiumExtensions: [String] = []
    /// Extra Chromium command-line switches, e.g. "disable-gpu" or "lang=en-US".
    public var chromiumFlags: [String] = []

    public init() {}

    static let animationParents: [String: String] = [
        "windows": "global", "windowsIn": "windows", "windowsOut": "windows", "windowsMove": "windows",
        "fade": "global", "fadeIn": "fade", "fadeOut": "fade", "fadeSwitch": "fade", "fadeShadow": "fade", "fadeDim": "fade",
        "border": "global", "borderangle": "border",
        "workspaces": "global", "workspacesIn": "workspaces", "workspacesOut": "workspaces",
        "specialWorkspace": "workspaces", "specialWorkspaceIn": "specialWorkspace", "specialWorkspaceOut": "specialWorkspace",
        "layers": "global", "layersIn": "layers", "layersOut": "layers",
        "fadeLayers": "fade", "fadeLayersIn": "fadeLayers", "fadeLayersOut": "fadeLayers",
    ]

    /// Resolves an animation by walking up Hyprland's animation tree.
    public func animation(_ name: String) -> ResolvedAnimation {
        var cur: String? = name
        var spec: AnimationSpec?
        while let c = cur {
            if let s = animations[c] { spec = s; break }
            cur = Self.animationParents[c]
        }
        let s = spec ?? AnimationSpec(enabled: true, speed: 8, curve: "default")
        // A child without its own style inherits the nearest ancestor's style.
        var style = s.style
        var p: String? = name
        while style == nil, let c = p {
            style = animations[c]?.style
            p = Self.animationParents[c]
        }
        return ResolvedAnimation(
            enabled: animationsEnabled && s.enabled && s.speed > 0,
            duration: s.speed / 10,
            curve: beziers[s.curve] ?? .hyprDefault,
            style: style)
    }
}

// MARK: Parser

public enum ConfigParser {
    public static func load(path: String) -> HyprmuxConfig {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            var c = parse(defaultConfig)
            c.errors.append("could not read \(expanded); using built-in defaults")
            return c
        }
        var c = parse(text, baseDir: (expanded as NSString).deletingLastPathComponent)
        c.sourcePath = expanded
        return c
    }

    public static func parse(_ text: String, baseDir: String? = nil) -> HyprmuxConfig {
        var state = State(baseDir: baseDir)
        state.run(text, file: "config", depth: 0)
        return state.config
    }

    struct State {
        var config = HyprmuxConfig()
        var vars: [String: String] = [:]
        var sections: [String] = []
        var submap = "reset"
        let baseDir: String?

        init(baseDir: String?) { self.baseDir = baseDir }

        mutating func error(_ file: String, _ line: Int, _ msg: String) {
            config.errors.append("\(file):\(line): \(msg)")
        }

        mutating func run(_ text: String, file: String, depth: Int) {
            for (i, rawLine) in text.components(separatedBy: .newlines).enumerated() {
                let lineNo = i + 1
                var line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line == "}" {
                    if sections.popLast() == nil { error(file, lineNo, "unexpected '}'") }
                    continue
                }
                if line.hasSuffix("{"), !line.contains("=") {
                    line.removeLast()
                    sections.append(line.trimmingCharacters(in: .whitespaces))
                    continue
                }
                guard let eq = line.firstIndex(of: "=") else {
                    error(file, lineNo, "expected 'key = value'")
                    continue
                }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = expand(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
                if key.hasPrefix("$") {
                    vars[String(key.dropFirst())] = value
                    continue
                }
                let full = (sections + [key]).joined(separator: ":")
                apply(full, value, file: file, line: lineNo, depth: depth)
            }
        }

        func stripComment(_ s: String) -> String {
            // "##" escapes a literal '#'.
            var out = ""
            var it = Array(s)
            var i = 0
            while i < it.count {
                if it[i] == "#" {
                    if i + 1 < it.count, it[i + 1] == "#" { out.append("#"); i += 2; continue }
                    break
                }
                out.append(it[i])
                i += 1
            }
            it.removeAll()
            return out
        }

        func expand(_ s: String) -> String {
            guard s.contains("$") else { return s }
            var out = s
            for name in vars.keys.sorted(by: { $0.count > $1.count }) {
                out = out.replacingOccurrences(of: "$" + name, with: vars[name]!)
            }
            return out
        }

        mutating func apply(_ key: String, _ value: String, file: String, line: Int, depth: Int) {
            func num() -> Double? {
                guard let v = Double(value) else { error(file, line, "\(key): expected a number, got '\(value)'"); return nil }
                return v
            }
            func bool() -> Bool? {
                switch value.lowercased() {
                case "1", "true", "yes", "on": return true
                case "0", "false", "no", "off": return false
                default: error(file, line, "\(key): expected a boolean, got '\(value)'"); return nil
                }
            }
            func insets() -> Insets? {
                let p = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                switch p.count {
                case 1: return Insets(all: p[0])
                case 2: return Insets(top: p[0], right: p[1], bottom: p[0], left: p[1])
                case 4: return Insets(top: p[0], right: p[1], bottom: p[2], left: p[3])
                default: error(file, line, "\(key): expected 1, 2 or 4 numbers"); return nil
                }
            }
            func list() -> [String] {
                value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            func gradient() -> Gradient? {
                guard let g = Gradient.parse(value) else { error(file, line, "\(key): bad color '\(value)'"); return nil }
                return g
            }

            if key.hasPrefix("ghostty:") {
                config.ghostty.append("\(key.dropFirst("ghostty:".count)) = \(value)")
                return
            }
            if key.hasPrefix("bind"), !key.contains(":") {
                parseBind(key, value, file: file, line: line)
                return
            }

            switch key {
            case "source":
                guard depth < 8 else { error(file, line, "source nested too deep"); return }
                var path = (value as NSString).expandingTildeInPath
                if !path.hasPrefix("/"), let base = baseDir { path = base + "/" + path }
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    error(file, line, "source: cannot read \(path)")
                    return
                }
                let saved = sections
                sections = []
                run(text, file: (path as NSString).lastPathComponent, depth: depth + 1)
                sections = saved
            case "submap": submap = value.isEmpty ? "reset" : value
            case "exec-once": config.execOnce.append(value)
            case "exec": config.exec.append(value)
            case "bezier", "animations:bezier":
                let p = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard p.count == 5, let a = Double(p[1]), let b = Double(p[2]), let c = Double(p[3]), let d = Double(p[4]) else {
                    error(file, line, "bezier: expected 'name, x1, y1, x2, y2'"); return
                }
                config.beziers[p[0]] = Bezier(a, b, c, d)
            case "animation", "animations:animation":
                let p = value.split(separator: ",", maxSplits: 4).map { $0.trimmingCharacters(in: .whitespaces) }
                guard p.count >= 2 else { error(file, line, "animation: expected 'name, on, speed, curve[, style]'"); return }
                let enabled = p[1] != "0"
                let speed = p.count > 2 ? Double(p[2]) ?? 8 : 8
                let curve = p.count > 3 ? p[3] : "default"
                if p.count > 3, config.beziers[curve] == nil { error(file, line, "animation: unknown bezier '\(curve)'") }
                config.animations[p[0]] = AnimationSpec(enabled: enabled, speed: speed, curve: curve, style: p.count > 4 ? p[4] : nil)
            case "general:gaps_in": if let v = insets() { config.wm.gapsIn = v }
            case "general:gaps_out": if let v = insets() { config.wm.gapsOut = v }
            case "general:border_size": if let v = num() { config.wm.borderSize = v }
            case "general:col.active_border": if let g = gradient() { config.activeBorder = g }
            case "general:col.inactive_border": if let g = gradient() { config.inactiveBorder = g }
            case "general:layout":
                if value != "dwindle" { error(file, line, "general:layout: only 'dwindle' is supported so far") }
            case "decoration:rounding": if let v = num() { config.rounding = v }
            case "decoration:rounding_power": if let v = num() { config.roundingPower = min(max(v, 1), 10) }
            case "decoration:active_opacity": if let v = num() { config.activeOpacity = v }
            case "decoration:inactive_opacity": if let v = num() { config.inactiveOpacity = v }
            case "decoration:dim_inactive": if let v = bool() { config.dimInactive = v }
            case "decoration:dim_strength": if let v = num() { config.dimStrength = v }
            case "decoration:dim_special": if let v = num() { config.dimSpecial = v }
            case "decoration:shadow:enabled", "decoration:drop_shadow": if let v = bool() { config.shadowEnabled = v }
            case "decoration:shadow:range", "decoration:shadow_range": if let v = num() { config.shadowRange = v }
            case "decoration:shadow:color", "decoration:col.shadow":
                if let c = Color.parse(value) { config.shadowColor = c } else { error(file, line, "\(key): bad color") }
            case "decoration:blur:enabled": if let v = bool() { config.blurEnabled = v }
            case "decoration:blur:size", "decoration:blur:passes", "decoration:blur:noise", "decoration:blur:contrast",
                 "decoration:blur:brightness", "decoration:blur:vibrancy", "decoration:blur:new_optimizations",
                 "decoration:blur:xray", "decoration:blur:ignore_opacity", "decoration:blur:popups":
                break  // Hyprland blur tuning; macOS blur has no equivalent knobs.
            case "animations:enabled": if let v = bool() { config.animationsEnabled = v }
            case "input:follow_mouse": if let v = num() { config.followMouse = Int(v) }
            case "dwindle:preserve_split": if let v = bool() { config.wm.dwindle.preserveSplit = v }
            case "dwindle:force_split": if let v = num() { config.wm.dwindle.forceSplit = Int(v) }
            case "dwindle:split_width_multiplier": if let v = num() { config.wm.dwindle.splitWidthMultiplier = v }
            case "dwindle:default_split_ratio": if let v = num() { config.wm.dwindle.defaultSplitRatio = v }
            case "binds:workspace_back_and_forth": if let v = bool() { config.wm.workspaceBackAndForth = v }
            case "misc:background_color":
                if let c = Color.parse(value) { config.backgroundColor = c } else { error(file, line, "\(key): bad color") }
            case "web:home": config.webHome = value
            case "web:search":
                if value.contains("%s") { config.webSearch = value } else { error(file, line, "web:search: needs %s for the query") }
            case "web:open_terminal_links": if let v = bool() { config.webOpenTerminalLinks = v }
            case "web:address_bar": if let v = bool() { config.webShowAddressBar = v }
            case "web:chromium_extensions":
                config.chromiumExtensions = value.split(separator: ",")
                    .map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
                    .filter { !$0.isEmpty }
            case "web:chromium_flags":
                config.chromiumFlags = value.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            case "web:engine":
                let v = value.lowercased()
                if v == "webkit" || v == "chromium" { config.webEngine = v } else { error(file, line, "web:engine: expected webkit or chromium") }
            case "misc:fullscreen_style":
                let v = value.lowercased()
                if v == "fill" || v == "native" { config.fullscreenStyle = v } else { error(file, line, "misc:fullscreen_style: expected fill or native") }
            case "group:border_size": if let v = num() { config.groupBorderSize = max(0, v) }
            case "group:auto_group": if let v = bool() { config.wm.autoGroup = v }
            case "group:col.border_active": if let g = gradient() { config.groupActiveBorder = g }
            case "group:col.border_inactive": if let g = gradient() { config.groupInactiveBorder = g }
            case "group:groupbar:enabled": if let v = bool() { config.groupbarEnabled = v }
            case "group:groupbar:height": if let v = num() { config.groupbarHeight = max(12, v) }
            case "group:groupbar:font_size": if let v = num() { config.groupbarFontSize = max(6, v) }
            case "group:groupbar:col.active": if let g = gradient() { config.groupbarActive = g.colors[0] }
            case "group:groupbar:col.inactive": if let g = gradient() { config.groupbarInactive = g.colors[0] }
            case "group:groupbar:text_color": if let g = gradient() { config.groupbarText = g.colors[0] }
            case "group:insert_after_current", "group:focus_removed_window", "group:merge_groups_on_drag",
                 "group:drag_into_group", "group:col.border_locked_active", "group:col.border_locked_inactive",
                 "group:groupbar:gradients", "group:groupbar:render_titles", "group:groupbar:scrolling",
                 "group:groupbar:font_family", "group:groupbar:col.locked_active", "group:groupbar:col.locked_inactive",
                 "group:groupbar:priority", "group:groupbar:stacked":
                break  // Hyprland group options without an equivalent here yet.
            case "hud:font_family": config.hud.fontFamily = value.isEmpty ? nil : value
            case "hud:font_size": if let v = num() { config.hud.fontSize = v > 0 ? min(max(v, 6), 72) : nil }
            case "hud:notifications:position":
                if let p = HUDPosition(config: value) {
                    config.hud.notificationPosition = p
                } else {
                    error(file, line, "\(key): expected one of \(HUDPosition.allCases.map(\.rawValue).joined(separator: ", "))")
                }
            case "hud:notifications:timeout": if let v = num() { config.hud.notificationTimeout = max(0, v) / 1000 }
            case "hud:notifications:max_visible": if let v = num() { config.hud.maxNotifications = max(1, Int(v)) }
            case "hud:notifications:width": if let v = num() { config.hud.notificationWidth = min(max(v, 160), 1200) }
            case "hud:picker:width": if let v = num() { config.hud.pickerWidth = min(max(v, 240), 1600) }
            case "hud:picker:max_rows": if let v = num() { config.hud.pickerMaxRows = min(max(1, Int(v)), 40) }
            case "session:restore": if let v = bool() { config.session.enabled = v }
            case "session:programs": config.session.programs = list()
            case "session:deny": config.session.deny = list()
            case _ where key.hasPrefix("session:resume:"):
                let kind = String(key.dropFirst("session:resume:".count))
                if value.contains("{id}") { config.session.resume[kind] = value } else { error(file, line, "\(key): needs {id} for the session id") }
            case _ where key.hasPrefix("session:start:"):
                config.session.start[String(key.dropFirst("session:start:".count))] = value
            case "workspace":
                // Hyprland workspace rule: "workspace = 3, defaultName:mail, persistent:true".
                // Only defaultName applies here; other rules are accepted and ignored.
                let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let first = parts.first, !first.isEmpty else { error(file, line, "workspace: expected 'ID, rules'"); return }
                guard let n = Int(first), n >= 1 else { return }  // name:/special: selectors: not supported yet
                for rule in parts.dropFirst() where rule.lowercased().hasPrefix("defaultname:") {
                    config.wm.workspaceNames[n] = String(rule.dropFirst("defaultname:".count)).trimmingCharacters(in: .whitespaces)
                }
            case "hyprmux:confirm_quit": if let v = bool() { config.confirmQuit = v }
            case "hyprmux:float_size": if let v = num() { config.wm.floatSizeFraction = min(max(v, 0.1), 1) }
            default:
                // Unknown keys are reported but never fatal, so Hyprland configs mostly load.
                error(file, line, "unknown option '\(key)'")
            }
        }

        mutating func parseBind(_ key: String, _ value: String, file: String, line: Int) {
            if key == "unbind" { return }
            let flags = Set(key.dropFirst(4))
            let allowed: Set<Character> = ["e", "l", "r", "n", "m", "d", "i", "o", "t"]
            guard flags.isSubset(of: allowed) else { error(file, line, "unknown bind flags '\(key)'"); return }
            let hasDescription = flags.contains("d")
            let maxParts = hasDescription ? 5 : 4
            var parts = value.split(separator: ",", maxSplits: maxParts - 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if hasDescription, parts.count >= 3 { parts.remove(at: 2) }
            guard parts.count >= 3 else { error(file, line, "\(key): expected 'MODS, key, dispatcher[, args]'"); return }
            let mods: Modifiers
            switch Modifiers.parse(parts[0]) {
            case .success(let m): mods = m
            case .failure(let e): error(file, line, "\(key): \(e)"); return
            }
            guard let trigger = KeyCodes.parse(parts[1]) else { error(file, line, "\(key): unknown key '\(parts[1])'"); return }
            let args = parts.count > 3 ? parts[3] : ""
            let dispatcher: Dispatcher
            if flags.contains("m") {
                // Mouse binds carry the action name only; the host interprets it.
                guard parts[2] == "movewindow" || parts[2] == "resizewindow" else {
                    error(file, line, "bindm: expected movewindow or resizewindow"); return
                }
                dispatcher = parts[2] == "movewindow" ? .moveActive(dx: 0, dy: 0) : .resizeActive(dx: 0, dy: 0)
            } else {
                switch Dispatcher.parse(parts[2], args) {
                case .success(let d): dispatcher = d
                case .failure(let e): error(file, line, "\(key): \(e)"); return
                }
            }
            config.binds.append(KeyBind(mods: mods, trigger: trigger, dispatcher: dispatcher, flags: flags, submap: submap))
        }
    }
}
