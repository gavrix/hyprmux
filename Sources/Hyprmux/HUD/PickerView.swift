import AppKit
import HyprmuxCore

/// The query field. Borderless: the panel supplies the look.
final class PickerField: NSTextField {
    var caretColor: NSColor = .white

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView { editor.insertionPointColor = caretColor }
        return ok
    }
}

/// The rows of a picker, drawn like a terminal list: a pointer on the selected row,
/// matched characters in the accent color, details faded after the title.
final class PickerListView: FlippedView {
    var picker: Picker
    var theme: HUDTheme
    /// Row icons by item id (the launcher's app icons). Empty: rows have none.
    var icons: [String: NSImage] = [:]
    var rowHeight: CGFloat = 24
    var sidePadding: CGFloat = 14
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    var onScroll: ((Int) -> Void)?
    private var scrollAccumulator: CGFloat = 0
    private var tracking: NSTrackingArea?

    init(picker: Picker, theme: HUDTheme) {
        self.picker = picker
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let font = theme.font, bold = theme.boldFont
        let lineH = ceil(font.ascender - font.descender)
        guard !picker.rows.isEmpty else {
            let q = picker.query.trimmingCharacters(in: .whitespaces)
            let text = picker.allowsCustom && !q.isEmpty ? "↩  use “\(q)”"
                : picker.items.isEmpty ? picker.emptyText ?? "No matches" : "No matches"
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: theme.secondary])
            s.draw(at: CGPoint(x: sidePadding + pointerWidth, y: (rowHeight - lineH) / 2))
            return
        }
        for (offset, row) in picker.visibleRows.enumerated() {
            let y = CGFloat(offset) * rowHeight
            let item = picker.items[row.index]
            let selected = picker.selection == picker.scroll + offset
            if selected {
                let r = CGRect(x: sidePadding - 6, y: y + 1, width: bounds.width - 2 * (sidePadding - 6), height: rowHeight - 2)
                theme.foreground.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
                let p = NSAttributedString(string: "›", attributes: [.font: bold, .foregroundColor: theme.accent])
                p.draw(at: CGPoint(x: sidePadding, y: y + (rowHeight - lineH) / 2))
            }
            let line = NSMutableAttributedString()
            line.append(highlighted(item.title, row.titleMatches, color: selected ? theme.foreground : theme.foreground.withAlphaComponent(0.85)))
            if !item.detail.isEmpty {
                line.append(NSAttributedString(string: "  ", attributes: [.font: font]))
                line.append(highlighted(item.detail, row.detailMatches, color: theme.secondary))
            }
            var x = sidePadding + pointerWidth
            if !icons.isEmpty {
                let side = max(12, rowHeight - 6)
                icons[item.id]?.draw(in: CGRect(x: x, y: y + (rowHeight - side) / 2, width: side, height: side),
                                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += side + 8
            }
            line.draw(with: CGRect(x: x, y: y + (rowHeight - lineH) / 2, width: bounds.width - x - sidePadding, height: lineH),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private var pointerWidth: CGFloat { ceil(("› " as NSString).size(withAttributes: [.font: theme.boldFont]).width) }

    private func highlighted(_ text: String, _ matches: [Int], color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [.font: theme.font, .foregroundColor: color])
        let chars = Array(text)
        var offset = 0
        for (i, c) in chars.enumerated() {
            let len = String(c).utf16.count
            if matches.contains(i) {
                s.addAttributes([.foregroundColor: theme.accent, .font: theme.boldFont], range: NSRange(location: offset, length: len))
            }
            offset += len
        }
        return s
    }

    private func row(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        let offset = Int(p.y / rowHeight)
        let row = picker.scroll + offset
        return p.y >= 0 && offset < picker.maxVisible && picker.rows.indices.contains(row) ? row : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { if let r = row(at: event) { onHover?(r) } }
    override func mouseDown(with event: NSEvent) { if let r = row(at: event) { onClick?(r) } }
    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : rowHeight)
        while abs(scrollAccumulator) >= rowHeight {
            onScroll?(scrollAccumulator > 0 ? -1 : 1)
            scrollAccumulator -= scrollAccumulator > 0 ? rowHeight : -rowHeight
        }
    }
}

/// A picker panel: `title ❯ query` with a match counter, then the rows.
/// Decorated like a focused tile.
final class PickerView: DecoratedView, NSTextFieldDelegate {
    private(set) var picker: Picker
    let field = PickerField()
    /// Holds everything at the panel's final size, centered in the clip, so a popin
    /// reveals it from the middle instead of dragging it along.
    private let content = FlippedView()
    private let promptLabel = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let separator = NSView()
    private let list: PickerListView
    private var theme: HUDTheme
    private var contentSize: CGSize = .zero

    var onChange: (() -> Void)?
    /// A row was clicked.
    var onPick: ((Int) -> Void)?

    init(picker: Picker, theme: HUDTheme, icons: [String: NSImage] = [:]) {
        self.picker = picker
        self.theme = theme
        list = PickerListView(picker: picker, theme: theme)
        list.icons = icons
        super.init(decoration: theme.decoration, active: true, blurBlending: .withinWindow)
        clip.addSubview(content)
        for l in [promptLabel, counter] {
            l.isSelectable = false
            l.drawsBackground = false
            l.isBordered = false
            l.lineBreakMode = .byClipping
            content.addSubview(l)
        }
        counter.alignment = .right
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.stringValue = picker.query
        content.addSubview(field)
        separator.wantsLayer = true
        content.addSubview(separator)
        content.addSubview(list)
        list.onClick = { [weak self] r in self?.onPick?(r) }
        list.onHover = { [weak self] r in
            guard let self, self.picker.selection != r else { return }
            self.picker.select(r)
            self.refresh()
        }
        list.onScroll = { [weak self] d in self?.move(d) }
        apply(theme)
        finishSetup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ t: HUDTheme) {
        theme = t
        setDecoration(t.decoration, active: true, borderDuration: 0)
        clip.layer?.backgroundColor = t.background.cgColor
        promptLabel.font = t.boldFont
        promptLabel.textColor = t.accent
        promptLabel.stringValue = picker.title.isEmpty ? "❯" : "\(picker.title) ❯"
        field.font = t.font
        field.textColor = t.foreground
        field.caretColor = t.accent
        (field.currentEditor() as? NSTextView)?.insertionPointColor = t.accent
        field.placeholderAttributedString = NSAttributedString(
            string: picker.placeholder ?? (picker.mode == .prompt ? "" : "type to filter"),
            attributes: [.font: t.font, .foregroundColor: t.secondary.withAlphaComponent(0.4)])
        counter.font = t.font
        counter.textColor = t.secondary
        separator.layer?.backgroundColor = t.foreground.withAlphaComponent(0.12).cgColor
        list.theme = t
        refresh()
    }

    /// Lays out for `width` and returns the panel height. The height stays fixed while
    /// filtering (from the unfiltered row count), so the panel doesn't jump.
    func layout(width: CGFloat) -> CGFloat {
        let d = decoration
        let t = theme
        let lineH = ceil(t.font.ascender - t.font.descender + t.font.leading)
        let headerH = lineH + 16
        let rowH = lineH + 8
        let rows = picker.mode == .list ? max(1, min(picker.items.count, picker.maxVisible)) : 0
        let innerW = width - 2 * d.borderSize
        let listH = rows > 0 ? CGFloat(rows) * rowH + 12 : 0
        let innerH = headerH + (rows > 0 ? 1 + listH : 0)
        // Keep the prompt clear of the corner curve.
        let r = min(max(0, d.rounding - d.borderSize), min(innerW, innerH) / 2)
        let inset = CGFloat(RoundedShape.edgeInset(radius: Double(r), power: Double(d.roundingPower), depth: Double(headerH / 2 - lineH / 2)))
        let hPad = max(14, ceil(inset) + 8)
        contentSize = CGSize(width: innerW, height: innerH)
        content.frame = CGRect(origin: .zero, size: contentSize)

        let promptW = ceil(promptLabel.intrinsicContentSize.width)
        let counterW: CGFloat = picker.mode == .list ? ceil(("999/999" as NSString).size(withAttributes: [.font: t.font]).width) : 0
        let y = (headerH - lineH) / 2
        promptLabel.frame = CGRect(x: hPad, y: y, width: promptW, height: lineH)
        counter.frame = CGRect(x: innerW - hPad - counterW, y: y, width: counterW, height: lineH)
        let fieldX = hPad + promptW + 8
        field.frame = CGRect(x: fieldX, y: y - 1, width: max(40, innerW - hPad - counterW - 8 - fieldX), height: lineH + 2)
        separator.isHidden = rows == 0
        separator.frame = CGRect(x: 0, y: headerH, width: innerW, height: 1)
        list.isHidden = rows == 0
        list.rowHeight = rowH
        list.sidePadding = hPad - 4
        list.frame = CGRect(x: 0, y: headerH + 1 + 6, width: innerW, height: max(0, listH - 12))
        refresh()
        return innerH + 2 * d.borderSize
    }

    override func chromeDidLayout() {
        // Centered in the clip: at full size this is the origin.
        let b = clip.bounds
        content.frame.origin = CGPoint(x: round((b.width - contentSize.width) / 2), y: round((b.height - contentSize.height) / 2))
    }

    func move(_ delta: Int) { picker.move(delta); refresh() }
    func select(_ row: Int) { picker.select(row); refresh() }
    func page(_ direction: Int) { picker.page(direction); refresh() }

    private func refresh() {
        counter.stringValue = picker.mode == .list ? "\(picker.rows.count)/\(picker.items.count)" : ""
        list.picker = picker
        list.needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        picker.setQuery(field.stringValue)
        refresh()
        onChange?()
    }
}

/// Covers the window under an open picker: a click outside the panel closes it.
final class PickerScrim: NSView {
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}
