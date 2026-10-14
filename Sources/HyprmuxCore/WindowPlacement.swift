import CoreGraphics

/// Where the monitor window goes when it leaves fill on a display.
public enum WindowPlacement {
    /// `frame` fitted into `area` (a screen's visible frame). With `from`, the area
    /// `frame` was placed in, it first keeps its offset from that area's origin, so a
    /// window saved on one display lands at the same spot on another. Then it shrinks
    /// to fit and moves fully inside.
    /// Which of `displays` a moved full-screen-sized window now belongs to: the one it
    /// covers the largest share of. Largest overlap would keep a window bigger than the
    /// new display on the old one: Window > Move to puts a 2560x1440 window at a
    /// 1512x982 display's corner, covering all of it and less of the old display.
    public static func display(for frame: CGRect, among displays: [CGRect]) -> Int? {
        func share(_ d: CGRect) -> CGFloat {
            let i = frame.intersection(d)
            return i.isNull || d.isEmpty ? 0 : (i.width * i.height) / (d.width * d.height)
        }
        guard let best = displays.indices.max(by: { share(displays[$0]) < share(displays[$1]) }),
              share(displays[best]) > 0 else { return nil }
        return best
    }

    public static func fit(_ frame: CGRect, from: CGRect? = nil, into area: CGRect) -> CGRect {
        var f = frame
        if let from, from != area {
            f.origin.x = area.minX + (frame.minX - from.minX)
            f.origin.y = area.minY + (frame.minY - from.minY)
        }
        f.size.width = min(f.width, area.width)
        f.size.height = min(f.height, area.height)
        f.origin.x = min(max(f.minX, area.minX), area.maxX - f.width)
        f.origin.y = min(max(f.minY, area.minY), area.maxY - f.height)
        return f
    }
}
