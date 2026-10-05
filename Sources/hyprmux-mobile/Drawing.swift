import AppKit
import HyprmuxClientKit
import IOSurface

/// CoreGraphics drawing into a client buffer, in points with a top-left origin, like the
/// protocol's coordinates. AppKit draws the text and SF Symbols.
enum Draw {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let background = NSColor.black
    static let bar = NSColor(white: 0.1, alpha: 1)
    static let symbol = NSColor(white: 0.85, alpha: 1)
    static let pressed = NSColor(white: 0.22, alpha: 1)
    static let text = NSColor(white: 0.75, alpha: 1)
    static let note = NSColor(white: 0.5, alpha: 1)

    /// Runs `body` with the buffer locked and an AppKit context on it.
    static func into(_ buffer: HMBuffer, scale: Double, _ body: (CGContext) -> Void) {
        IOSurfaceLock(buffer.surface, [], nil)
        defer { IOSurfaceUnlock(buffer.surface, [], nil) }
        guard let ctx = CGContext(
            data: IOSurfaceGetBaseAddress(buffer.surface), width: buffer.width, height: buffer.height,
            bitsPerComponent: 8, bytesPerRow: buffer.bytesPerRow, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        ctx.translateBy(x: 0, y: CGFloat(buffer.height))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.current = previous
    }

    static func fill(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    /// Text centered in `rect`, wrapped to its width.
    static func text(_ s: String, in rect: CGRect, size: CGFloat, color: NSColor = text, weight: NSFont.Weight = .regular) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        ]
        let string = NSAttributedString(string: s, attributes: attrs)
        let bounds = string.boundingRect(with: CGSize(width: rect.width, height: rect.height),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let y = rect.minY + max(0, (rect.height - bounds.height) / 2)
        string.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: bounds.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// An SF Symbol, centered in `rect`.
    static func symbol(_ name: String, in rect: CGRect, size: CGFloat = 13, color: NSColor = symbol) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The largest rect of `size`'s aspect ratio that fits in `area`, centered.
    static func aspectFit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: area.minX + (area.width - fitted.width) / 2, y: area.minY + (area.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}
