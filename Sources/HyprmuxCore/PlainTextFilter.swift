// Used by `hyprmuxctl run` (Sources/hyprmuxctl/Run.swift).

/// Turns a terminal's output into plain text for a reader that isn't a terminal: drops
/// escape sequences and control characters, makes CRLF a newline, and lets a lone
/// carriage return start the line over, so a progress bar leaves only its last state.
/// Emits whole lines; `finish` emits the rest.
public struct PlainTextFilter {
    public init() {}

    private enum State { case text, escape, csi, string, stringEscape, charset }
    private var state = State.text
    private var line: [UInt8] = []
    private var pendingCR = false

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        for b in bytes { step(b, &out) }
        return out
    }

    public mutating func finish() -> [UInt8] {
        let rest = line
        line = []
        return rest
    }

    private mutating func step(_ b: UInt8, _ out: inout [UInt8]) {
        switch state {
        case .escape:
            switch b {
            case UInt8(ascii: "["): state = .csi
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                state = .string
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"): state = .charset
            default: state = .text
            }
            return
        case .csi:
            if (0x40...0x7E).contains(b) { state = .text }
            return
        case .string:
            if b == 0x07 { state = .text } else if b == 0x1B { state = .stringEscape }
            return
        case .stringEscape:
            state = b == UInt8(ascii: "\\") ? .text : .string
            return
        case .charset:
            state = .text
            return
        case .text:
            break
        }
        // A CR starts the line over, unless a newline follows. A terminal turns a
        // program's "\r\n" into "\r\r\n", so several CRs count as one.
        if pendingCR, b != 0x0D {
            pendingCR = false
            if b != 0x0A { line.removeAll() }
        }
        switch b {
        case 0x1B: state = .escape
        case 0x0D: pendingCR = true
        case 0x0A:
            out += line
            out.append(0x0A)
            line.removeAll()
        case 0x08: if !line.isEmpty { line.removeLast() }
        case 0x09: line.append(b)
        case 0..<0x20, 0x7F: break
        default: line.append(b)
        }
    }
}
