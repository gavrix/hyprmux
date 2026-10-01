import Foundation

/// fzf-style fuzzy matching: every query character must appear in order.
/// Space-separated terms must all match, anywhere.
public enum FuzzyMatch {
    public struct Result: Equatable, Sendable {
        public var score: Int
        /// Matched character offsets in the text, ascending.
        public var positions: [Int]
    }

    static let scoreMatch = 16
    static let bonusBoundary = 10
    static let bonusConsecutive = 8
    static let bonusFirstChar = 6
    static let penaltyGapStart = 3
    static let penaltyGapExtension = 1

    /// Smart case, like fzf: case-insensitive unless the query has an uppercase letter.
    public static func match(_ query: String, in text: String) -> Result? {
        let terms = query.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return Result(score: 0, positions: []) }
        let chars = Array(text)
        var total = 0
        var positions = Set<Int>()
        for term in terms {
            guard let r = matchTerm(Array(term), in: chars) else { return nil }
            total += r.score
            positions.formUnion(r.positions)
        }
        return Result(score: total, positions: positions.sorted())
    }

    /// Best-scoring placement of `pattern` in `text`, by dynamic programming over
    /// (pattern index, text index) in O(m·n), like fzf's v2 algorithm without its limits.
    private static func matchTerm(_ pattern: [Character], in text: [Character]) -> Result? {
        let caseSensitive = pattern.contains { $0.isUppercase }
        let t = caseSensitive ? text : text.map { Character($0.lowercased()) }
        let p = caseSensitive ? pattern : pattern.map { Character($0.lowercased()) }
        let m = p.count, n = t.count
        guard m > 0, m <= n else { return m == 0 ? Result(score: 0, positions: []) : nil }
        let none = Int.min / 4
        // best[k][i]: top score with p[k] matched at t[i]; from[k][i]: where p[k-1] sat.
        var best = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        let boundary = (0..<n).map { isBoundary(text, $0) }
        for i in 0..<n where t[i] == p[0] {
            best[0][i] = scoreMatch + (boundary[i] ? bonusBoundary + bonusFirstChar : 0) - min(i, 10)
        }
        if m > 1 {
            for k in 1..<m {
                // Running best of best[k-1][j] + ext*j over j < i-1, for the gap term
                // -(start + ext*(i-j-2)) = -(start - 2*ext) - ext*i + ext*j.
                var gapBest = none, gapFrom = -1
                for i in 1..<n {
                    if i >= 2, best[k - 1][i - 2] > none {
                        let v = best[k - 1][i - 2] + penaltyGapExtension * (i - 2)
                        if v > gapBest { gapBest = v; gapFrom = i - 2 }
                    }
                    guard t[i] == p[k] else { continue }
                    let base = scoreMatch + (boundary[i] ? bonusBoundary : 0)
                    var top = none, at = -1
                    if best[k - 1][i - 1] > none {
                        top = best[k - 1][i - 1] + bonusConsecutive
                        at = i - 1
                    }
                    if gapBest > none {
                        let v = gapBest - (penaltyGapStart - 2 * penaltyGapExtension) - penaltyGapExtension * i
                        if v > top { top = v; at = gapFrom }
                    }
                    if at >= 0 {
                        best[k][i] = top + base
                        from[k][i] = at
                    }
                }
            }
        }
        guard let end = (0..<n).max(by: { best[m - 1][$0] < best[m - 1][$1] }), best[m - 1][end] > none else { return nil }
        var positions = [Int](repeating: 0, count: m)
        var i = end
        for k in stride(from: m - 1, through: 0, by: -1) {
            positions[k] = i
            i = from[k][i]
        }
        return Result(score: best[m - 1][end], positions: positions)
    }

    /// Start of the text, after a separator, or a lower-to-upper case change.
    static func isBoundary(_ text: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = text[i - 1], c = text[i]
        if " -_./:()[]'\"".contains(prev) { return true }
        return prev.isLowercase && c.isUppercase
    }
}

/// One row in a picker.
public struct PickerItem: Equatable, Sendable {
    /// What the picker returns when this row is chosen.
    public var id: String
    public var title: String
    /// Secondary text after the title (a runtime, a path, a key). Also searched.
    public var detail: String

    public init(id: String, title: String, detail: String = "") {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public enum PickerResult: Equatable, Sendable {
    case item(String)
    /// Typed text: a prompt's answer, or list input that matched nothing (when allowed).
    case text(String)
}

/// The state of a picker: a filtered, scored list with a selection, or a plain text prompt.
/// The app draws it and feeds it keys.
public struct Picker: Sendable {
    public enum Mode: Sendable { case list, prompt }

    public struct Row: Equatable, Sendable {
        public var index: Int
        public var score: Int
        /// Matched character offsets in the title.
        public var titleMatches: [Int]
        /// Matched character offsets in the detail.
        public var detailMatches: [Int]
    }

    public let title: String
    public let mode: Mode
    public let items: [PickerItem]
    /// List mode: Enter with no matching row returns the typed text.
    public let allowsCustom: Bool
    /// Rows shown at once; the list scrolls to keep the selection in view.
    public let maxVisible: Int
    /// Whether the filter looks at details too. Off where details are just counts, so
    /// typing "12" doesn't match workspace 1's "2 windows".
    public let searchesDetail: Bool
    /// Hint shown in the empty query field.
    public var placeholder: String?
    /// The one disabled row shown when the picker has no items at all ("No apps").
    public var emptyText: String?

    public private(set) var query = ""
    public private(set) var rows: [Row] = []
    /// Index into `rows`. Nil when nothing matches.
    public private(set) var selection: Int?
    /// First row in view.
    public private(set) var scroll = 0

    public init(title: String, items: [PickerItem] = [], mode: Mode = .list, allowsCustom: Bool = false,
                searchesDetail: Bool = true, query: String = "", maxVisible: Int = 10) {
        self.title = title
        self.searchesDetail = searchesDetail
        self.items = items
        self.mode = mode
        self.allowsCustom = allowsCustom
        self.maxVisible = max(1, maxVisible)
        setQuery(query)
    }

    public var visibleRows: ArraySlice<Row> {
        rows[scroll..<min(rows.count, scroll + maxVisible)]
    }

    public mutating func setQuery(_ q: String) {
        query = q
        guard mode == .list else { return }
        let q = q.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            rows = items.indices.map { Row(index: $0, score: 0, titleMatches: [], detailMatches: []) }
        } else {
            rows = items.enumerated().compactMap { i, item in
                // Title and detail are searched as one line; the offsets are split back afterwards.
                let line = item.detail.isEmpty || !searchesDetail ? item.title : item.title + " " + item.detail
                guard let m = FuzzyMatch.match(q, in: line) else { return nil }
                let n = item.title.count
                return Row(index: i, score: m.score, titleMatches: m.positions.filter { $0 < n },
                           detailMatches: m.positions.filter { $0 > n }.map { $0 - n - 1 })
            }
            rows.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                let la = items[a.index].title.count, lb = items[b.index].title.count
                if la != lb { return la < lb }
                return a.index < b.index
            }
        }
        selection = rows.isEmpty ? nil : 0
        scroll = 0
    }

    /// Moves the selection by `delta` rows, wrapping around the ends.
    public mutating func move(_ delta: Int) {
        guard let s = selection, !rows.isEmpty else { return }
        let n = rows.count
        select(((s + delta) % n + n) % n)
    }

    /// A page up or down, stopping at the ends.
    public mutating func page(_ direction: Int) {
        guard let s = selection else { return }
        select(min(max(s + direction * maxVisible, 0), rows.count - 1))
    }

    /// Selects a row (an index into `rows`) and scrolls it into view.
    public mutating func select(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        selection = row
        if row < scroll { scroll = row }
        if row >= scroll + maxVisible { scroll = row - maxVisible + 1 }
    }

    public var selectedItem: PickerItem? { selection.map { items[rows[$0].index] } }

    /// What Enter returns now. Nil means Enter does nothing (no match, custom text not allowed).
    public var result: PickerResult? {
        switch mode {
        case .prompt:
            return .text(query)
        case .list:
            if let item = selectedItem { return .item(item.id) }
            let q = query.trimmingCharacters(in: .whitespaces)
            return allowsCustom && !q.isEmpty ? .text(q) : nil
        }
    }
}

/// Rows and results for the workspace pickers (`picker, workspace` and friends).
public enum WorkspacePicker {
    public static func items(_ choices: [WindowManager.WorkspaceChoice]) -> [PickerItem] {
        choices.map { c in
            let title: String
            switch c.id {
            case .regular(let n): title = c.name.map { "\(n)  \($0)" } ?? "\(n)"
            case .special(let s): title = "special:\(s)"
            }
            var detail = c.windows == 0 ? "empty" : c.windows == 1 ? "1 window" : "\(c.windows) windows"
            if c.active { detail += " · current" }
            return PickerItem(id: c.id.description, title: title, detail: detail)
        }
    }

    /// Where a picker result points: a listed workspace, a typed number, or a typed name
    /// (an existing one, or a new workspace that takes the name).
    public static func target(for r: PickerResult) -> WorkspaceTarget? {
        switch r {
        case .item(let id):
            return WorkspaceTarget(hyprland: id)
        case .text(let q):
            let s = q.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            if let n = Int(s), n >= 1 { return .id(n) }
            return .named(s)
        }
    }
}
