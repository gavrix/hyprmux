import Foundation
import HyprmuxTour

/// The tour's own terminal: raw keyboard input, the alternate screen, and drawing.
final class Terminal {
    private var saved = termios()
    private var raw = false
    private var lastFrame: [String] = []

    var size: (columns: Int, rows: Int) {
        var w = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 else { return (80, 24) }
        return (Int(w.ws_col), Int(w.ws_row))
    }

    /// Keys arrive one at a time, unechoed. ⌃C still interrupts.
    func enter() {
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return }
        var t = saved
        t.c_lflag &= ~tcflag_t(ICANON | ECHO)
        t.c_cc.16 = 0  // VMIN
        t.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        raw = true
        write("\u{1B}[?1049h\u{1B}[?25l")
    }

    func leave() {
        write("\u{1B}[?25h\u{1B}[?1049l")
        if raw { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
        raw = false
    }

    func write(_ s: String) {
        let bytes = Array(s.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            offset += n
        }
    }

    /// Reads the keys that arrived (after `poll` said there are some).
    func readInput() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        return n > 0 ? Array(buffer[0..<n]) : []
    }

    /// Draws a frame, but only when it changed.
    func draw(_ lines: [String]) {
        guard lines != lastFrame else { return }
        lastFrame = lines
        var out = "\u{1B}[H"
        for (i, line) in lines.enumerated() {
            out += line + "\u{1B}[0m\u{1B}[K"
            if i < lines.count - 1 { out += "\r\n" }
        }
        out += "\u{1B}[J"
        write(out)
    }

    /// Forces the next `draw` to repaint (after a resize).
    func invalidate() { lastFrame = [] }

    /// A notification in Hyprmux (OSC 9). Clicking it focuses this tile.
    func notify(_ text: String) { write("\u{1B}]9;\(text)\u{07}") }

    func setTitle(_ text: String) { write("\u{1B}]2;\(text)\u{07}") }

    // MARK: Styles

    /// Paragraph tones: normal text, or everything dimmed (done tasks, notes).
    enum Tone { case normal, dim }

    static func sgr(_ style: TourStyle, tone: Tone) -> String {
        let dim = tone == .dim
        let codes: String
        switch style {
        case .plain: codes = dim ? "2" : ""
        case .key: codes = dim ? "2;7" : "1;7"
        case .code: codes = dim ? "2;36" : "36"
        case .bold: codes = dim ? "2;1" : "1"
        case .dim: codes = "2"
        case .success: codes = "32"
        case .accent: codes = "35"
        case .warning: codes = "33"
        }
        return "\u{1B}[0" + (codes.isEmpty ? "" : ";" + codes) + "m"
    }

    static func render(_ cells: [TourWrap.Cell], tone: Tone) -> String {
        var out = ""
        var current: TourStyle?
        for c in cells {
            if c.style != current {
                out += sgr(c.style, tone: tone)
                current = c.style
            }
            out.append(c.character)
        }
        return out + "\u{1B}[0m"
    }
}
