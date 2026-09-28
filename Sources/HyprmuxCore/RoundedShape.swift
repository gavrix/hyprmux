import CoreGraphics
import Foundation

/// Rounded-rectangle outlines with superellipse corners, like Hyprland's
/// `decoration:rounding_power`.
///
/// Each corner follows |x|^p + |y|^p = 1, scaled to the corner radius:
/// p = 2 is a circular arc (a classic rounded rect), p = 4 a squircle, and
/// larger values approach a square corner that still eases into the edges.
public enum RoundedShape {
    /// Points per corner. Enough that the polygon reads as a curve even at large radii.
    static let samples = 24

    /// How far in from a side edge content must start so that, `depth` points below the
    /// top (or above the bottom), it clears the corner curve. For bars along an edge.
    public static func edgeInset(radius: Double, power: Double, depth: Double) -> Double {
        let r = max(0, radius), p = min(max(power, 1), 10)
        guard r > 0, depth < r else { return 0 }
        // Corner curve (distance from the corner's center): (u/r)^p + (v/r)^p = 1,
        // with v = r - depth; solve for u, the inset is r - u.
        let v = (r - max(0, depth)) / r
        let u = pow(max(0, 1 - pow(v, p)), 1 / p)
        return r - r * u
    }

    public static func path(in rect: CGRect, radius: Double, power: Double) -> CGPath {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        guard r > 0.01 else { return CGPath(rect: rect, transform: nil) }
        let p = min(max(power, 1), 10)
        let path = CGMutablePath()
        // Corner centers, going clockwise from top-left (in a y-down space; the
        // shape is symmetric, so y-up views get the same outline).
        let corners: [(cx: Double, cy: Double, sx: Double, sy: Double, start: Double)] = [
            (rect.minX + r, rect.minY + r, -1, -1, .pi),          // top-left
            (rect.maxX - r, rect.minY + r, 1, -1, 1.5 * .pi),     // top-right
            (rect.maxX - r, rect.maxY - r, 1, 1, 0),              // bottom-right
            (rect.minX + r, rect.maxY - r, -1, 1, 0.5 * .pi),     // bottom-left
        ]
        let e = 2 / p
        for (i, c) in corners.enumerated() {
            for k in 0...samples {
                // Walk each quarter from one edge to the next.
                let t = c.start + Double(k) / Double(samples) * (.pi / 2)
                let ct = cos(t), st = sin(t)
                let x = c.cx + r * copysign(pow(abs(ct), e), ct)
                let y = c.cy + r * copysign(pow(abs(st), e), st)
                if i == 0 && k == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
        path.closeSubpath()
        return path
    }
}
