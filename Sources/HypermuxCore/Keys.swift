/// Modifier set used by binds. Maps SUPER to the macOS Command key.
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let ctrl = Modifiers(rawValue: 1 << 1)
    public static let alt = Modifiers(rawValue: 1 << 2)
    public static let `super` = Modifiers(rawValue: 1 << 3)

    /// Parses "SUPER SHIFT", "SUPER_SHIFT", "CMD+ALT", etc.
    public static func parse(_ s: String) -> Result<Modifiers, ParseError> {
        var m: Modifiers = []
        let tokens = s.uppercased().split(whereSeparator: { " _+|".contains($0) })
        for t in tokens {
            switch t {
            case "SHIFT": m.insert(.shift)
            case "CTRL", "CONTROL": m.insert(.ctrl)
            case "ALT", "OPT", "OPTION", "MOD1": m.insert(.alt)
            case "SUPER", "CMD", "COMMAND", "WIN", "LOGO", "MOD4", "META": m.insert(.super)
            default: return .failure(ParseError("unknown modifier '\(t)'"))
            }
        }
        return .success(m)
    }
}

public enum BindTrigger: Hashable, Sendable {
    /// macOS virtual key code (physical key, layout independent).
    case key(UInt16)
    /// Mouse button, Linux evdev numbering like Hyprland: 272 left, 273 right, 274 middle.
    case mouse(Int)
}

/// Maps Hyprland/xkb key names to macOS virtual key codes (ANSI positions).
public enum KeyCodes {
    public static func parse(_ raw: String) -> BindTrigger? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("code:"), let n = UInt16(s.dropFirst(5)) { return .key(n) }
        if s.lowercased().hasPrefix("mouse:"), let n = Int(s.dropFirst(6)) { return .mouse(n) }
        if let c = table[s.lowercased()] { return .key(c) }
        return nil
    }

    public static let table: [String: UInt16] = {
        var t: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
            "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "bracketright": 0x1E, "o": 0x1F,
            "u": 0x20, "bracketleft": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26,
            "apostrophe": 0x27, "k": 0x28, "semicolon": 0x29, "backslash": 0x2A, "comma": 0x2B,
            "slash": 0x2C, "n": 0x2D, "m": 0x2E, "period": 0x2F, "tab": 0x30, "space": 0x31,
            "grave": 0x32, "backspace": 0x33, "escape": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "home": 0x73, "end": 0x77, "prior": 0x74, "next": 0x79, "delete": 0x75,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
            "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        ]
        // Common aliases.
        let aliases: [String: String] = [
            "enter": "return", "esc": "escape", "pageup": "prior", "page_up": "prior",
            "pagedown": "next", "page_down": "next", "quote": "apostrophe", "backquote": "grave",
            "=": "equal", "-": "minus", "[": "bracketleft", "]": "bracketright", ";": "semicolon",
            "'": "apostrophe", ",": "comma", ".": "period", "/": "slash", "\\": "backslash", "`": "grave",
            "plus": "equal",
        ]
        for (a, b) in aliases { t[a] = t[b] }
        return t
    }()
}
