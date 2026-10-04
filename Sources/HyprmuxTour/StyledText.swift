import Foundation

/// How one character of tour text is drawn. The terminal maps each style to ANSI codes,
/// so colors come from the user's own terminal palette.
public enum TourStyle: Equatable, Sendable {
    case plain
    /// A shortcut, drawn as a keycap.
    case key
    /// A command, path, or config value.
    case code
    case bold
    case dim
    case success
    case accent
    case warning
}

/// A run of text in one style.
public struct TourSpan: Equatable, Sendable {
    public var text: String
    public var style: TourStyle

    public init(_ text: String, _ style: TourStyle = .plain) {
        self.text = text
        self.style = style
    }
}

/// A paragraph: spans that wrap together.
public typealias TourLine = [TourSpan]

/// Inline markup for step text, so steps read as plain sentences:
/// `key(_:)` marks a key, `` `path` `` is code, `*word*` is bold. Keys use private-use
/// delimiters, since chords themselves can contain brackets and backticks (⌘`).
public enum TourMarkup {
    static let keyOpen: Character = "\u{E000}"
    static let keyClose: Character = "\u{E001}"

    public static func parse(_ s: String, base: TourStyle = .plain) -> TourLine {
        var spans: [TourSpan] = []
        var current = ""
        var style = base
        func flush() {
            if !current.isEmpty { spans.append(TourSpan(current, style)) }
            current = ""
        }
        for ch in s {
            switch (ch, style) {
            case (keyOpen, base):
                flush()
                style = .key
            case (keyClose, .key):
                flush()
                style = base
            case ("`", base):
                flush()
                style = .code
            case ("`", .code):
                flush()
                style = base
            case ("*", base):
                flush()
                style = .bold
            case ("*", .bold):
                flush()
                style = base
            default:
                current.append(ch)
            }
        }
        flush()
        return spans
    }

    /// A key for markup, or a readable stand-in when the user's config doesn't bind it.
    public static func key(_ chord: String?, unbound action: String) -> String {
        guard let chord else { return "`\(action)` (unbound in your config)" }
        return "\(keyOpen)\(chord)\(keyClose)"
    }
}

/// Word wrapping for styled text. Keys never break, and get a space of padding on each
/// side so they read as keycaps.
public enum TourWrap {
    public struct Cell: Equatable, Sendable {
        public var character: Character
        public var style: TourStyle
    }

    public static func cells(_ line: TourLine) -> [Cell] {
        var out: [Cell] = []
        for span in line {
            if span.style == .key {
                // Non-breaking padding: a keycap is one word.
                out.append(Cell(character: "\u{00A0}", style: .key))
                out += span.text.map { Cell(character: $0 == " " ? "\u{00A0}" : $0, style: .key) }
                out.append(Cell(character: "\u{00A0}", style: .key))
            } else {
                out += span.text.map { Cell(character: $0, style: span.style) }
            }
        }
        return out
    }

    /// Breaks a paragraph into rows no wider than `width`, after `indent` columns on
    /// continuation rows. Words wider than a row are cut.
    public static func wrap(_ line: TourLine, width: Int, indent: Int = 0) -> [[Cell]] {
        let width = max(width, 8)
        let all = cells(line)
        // Words keep their trailing space, so styled spaces survive.
        var words: [[Cell]] = []
        var word: [Cell] = []
        for c in all {
            if c.character == " " {
                word.append(c)
                words.append(word)
                word = []
            } else {
                word.append(c)
            }
        }
        if !word.isEmpty { words.append(word) }

        var rows: [[Cell]] = []
        var row: [Cell] = []
        func trimmed(_ r: [Cell]) -> [Cell] {
            var r = r
            while r.last?.character == " " { r.removeLast() }
            return r
        }
        for var w in words {
            let limit = rows.isEmpty ? width : width - indent
            let visible = trimmed(w).count
            if !row.isEmpty, row.count + visible > limit {
                rows.append(trimmed(row))
                row = []
            }
            let rowLimit = rows.isEmpty ? width : width - indent
            while trimmed(w).count > rowLimit, row.isEmpty {
                rows.append(Array(w.prefix(rowLimit)))
                w = Array(w.dropFirst(rowLimit))
            }
            row += w
        }
        if !row.isEmpty || rows.isEmpty { rows.append(trimmed(row)) }
        if indent > 0 {
            for i in rows.indices.dropFirst() {
                rows[i] = Array(repeating: Cell(character: " ", style: .plain), count: indent) + rows[i]
            }
        }
        return rows
    }
}

extension TourMarkup {
    /// The text without markup, for places that can't style it (notifications, titles).
    public static func hasKey(_ s: String) -> Bool { s.contains(keyOpen) }

    public static func plain(_ s: String) -> String {
        parse(s).map(\.text).joined()
    }
}
