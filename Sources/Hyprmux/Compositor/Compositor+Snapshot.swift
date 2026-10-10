import AppKit
import HyprmuxCore

/// `hyprmuxctl snapshot` for tiles without their own frame (terminals, web tiles): the
/// tile as it shows in the window, decoration included, with a margin so what sits on
/// or outside its border (the title pill, the shadow) is in the picture.
extension Compositor {
    func writeWindowSnapshot(of id: ClientID, to url: URL) throws {
        guard let v = views[id], !v.isHidden else { throw SnapshotError("surface \(id.raw) isn't shown") }
        let margin: CGFloat = 16
        let inWindow = v.convert(v.bounds, to: nil).insetBy(dx: -margin, dy: -margin)
        // A window may capture itself without Screen Recording permission. The API is
        // unavailable to Swift on newer SDKs, so it's looked up at run time.
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            throw SnapshotError("window capture isn't available")
        }
        let capture = unsafeBitCast(sym, to: Capture.self)
        let options = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        guard let image = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                  CGWindowID(window.windowNumber), options)?.takeRetainedValue() else {
            throw SnapshotError("couldn't capture the window")
        }
        // The image is the window's content in pixels, top-left origin.
        let scale = CGFloat(image.width) / window.frame.width
        let height = window.frame.height
        let crop = CGRect(x: inWindow.minX * scale, y: (height - inWindow.maxY) * scale,
                          width: inWindow.width * scale, height: inWindow.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let tile = image.cropping(to: crop.integral),
              let png = NSBitmapImageRep(cgImage: tile).representation(using: .png, properties: [:]) else {
            throw SnapshotError("couldn't encode the PNG")
        }
        try png.write(to: url)
    }
}

struct SnapshotError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
