import AppKit
import HyprmuxCore

/// What a tile's content is doing: an agent's state in a terminal, or what an app
/// tile set (`toplevel.set_status`). The same names: working, blocked, done.
enum TileStatus {
    static func color(_ status: String?) -> NSColor? {
        switch status {
        case "working": .systemOrange
        case "blocked": .systemRed
        case "done": .systemGreen
        default: nil
        }
    }

    static func label(_ status: String?) -> String? {
        switch status {
        case "working": "working"
        case "blocked": "needs you"
        case "done": "done"
        default: nil
        }
    }
}

/// A small pill in a tile's top-right corner: what its content is doing.
final class StatusBadge: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        textColor = .white
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(_ status: String?) {
        stringValue = TileStatus.label(status) ?? ""
        layer?.backgroundColor = (TileStatus.color(status) ?? .clear).withAlphaComponent(0.85).cgColor
        isHidden = stringValue.isEmpty
    }

    override func sizeToFit() {
        super.sizeToFit()
        frame.size = CGSize(width: frame.width + 16, height: max(16, frame.height + 2))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
