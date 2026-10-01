// hyprmux-demo-client: the first client of docs/CLIENT_PROTOCOL.md.
//
// Draws with CoreGraphics straight into the swapchain's IOSurfaces. It animates on
// every frame callback, so a hidden tile (no callbacks) costs nothing. It shows the
// pointer, buttons, scrolling, focus, and typed keys, and quits when Hyprmux asks.
//
//   hyprmuxctl new-surface --type app -- "$(swift build --show-bin-path)/hyprmux-demo-client"
import CoreGraphics
import CoreText
import Foundation
import HyprmuxClientKit
import IOSurface

let client = HMClient(appID: "dev.gavrix.hyprmux.demo", name: "Demo client")
do { try client.connect() } catch {
    FileHandle.standardError.write("hyprmux-demo-client: \(error)\n".data(using: .utf8)!)
    exit(1)
}
client.onDisconnect = { reason in
    FileHandle.standardError.write("hyprmux-demo-client: \(reason)\n".data(using: .utf8)!)
    exit(0)
}

struct DemoState {
    var pointer: CGPoint?
    var buttons: Set<Int> = []
    var scroll = CGPoint.zero
    var focused = false
    var typed = ""
    var lastKey = "—"
    var frames = 0
    var fps = 0.0
    var lastFrame: CFAbsoluteTime = 0
    var waiting = false
}

var state = DemoState()
let start = CFAbsoluteTimeGetCurrent()
let top = client.makeToplevel(title: "Demo client")

top.onConfigure = { _ in if !state.waiting { draw() } }
top.onKeyboardFocus = { state.focused = $0 }
top.onCloseRequested = {
    top.destroy()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
}
top.onPointer = { event in
    switch event {
    case .enter(let x, let y): state.pointer = CGPoint(x: x, y: y); top.setCursor("crosshair")
    case .leave: state.pointer = nil
    case .motion(let x, let y, _, _): state.pointer = CGPoint(x: x, y: y)
    case .button(let x, let y, let b, let down, _, _):
        state.pointer = CGPoint(x: x, y: y)
        if down { state.buttons.insert(b) } else { state.buttons.remove(b) }
    case .scroll(_, _, let dx, let dy, _, _, _, _, _):
        state.scroll.x += dx; state.scroll.y += dy
    }
}
top.onKey = { key in
    guard key.down else { return }
    let printable = key.characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } && !key.characters.isEmpty
    if key.keyCode == 51 { if !state.typed.isEmpty { state.typed.removeLast() } }  // delete
    else if printable, key.modifiers & (1 << 20) == 0 { state.typed += key.characters }  // not with ⌘
    if state.typed.count > 48 { state.typed.removeFirst(state.typed.count - 48) }
    state.lastKey = "key \(key.keyCode) \"\(key.characters)\"\(key.isRepeat ? " (repeat)" : "")"
    // Echo typing into the title, so `hyprmuxctl surfaces` shows the input round trip.
    top.setTitle(state.typed.isEmpty ? "Demo client" : "Demo client: \(state.typed)")
}

/// HM_DEMO_STATS=1 prints the frame rate and drawing time every two seconds.
let printStats = ProcessInfo.processInfo.environment["HM_DEMO_STATS"] == "1"
var statFrames = 0
var statDrawTime = 0.0
var statStart = CFAbsoluteTimeGetCurrent()

func draw() {
    guard let c = top.configuration else { return }
    guard let buffer = top.acquireBuffer() else {
        // Every buffer is on screen; try again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { draw() }
        return
    }
    let now = CFAbsoluteTimeGetCurrent()
    if state.lastFrame > 0 {
        let instant = 1 / max(now - state.lastFrame, 0.001)
        state.fps = state.fps == 0 ? instant : state.fps * 0.9 + instant * 0.1
    }
    state.lastFrame = now
    state.frames += 1
    render(into: buffer, config: c, time: now - start)
    if printStats {
        statFrames += 1
        statDrawTime += CFAbsoluteTimeGetCurrent() - now
        if now - statStart >= 2 {
            let line = String(format: "%.1f fps, drawing %.1f ms/frame, %d×%d px\n", Double(statFrames) / (now - statStart),
                              statDrawTime / Double(statFrames) * 1000, buffer.width, buffer.height)
            FileHandle.standardError.write(line.data(using: .utf8)!)
            statFrames = 0; statDrawTime = 0; statStart = now
        }
    }
    state.waiting = true
    top.present(buffer) { _ in
        state.waiting = false
        draw()
    }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
let titleFont = CTFontCreateWithName("Menlo-Bold" as CFString, 22, nil)

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

func hsb(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
    let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let (r, g, b) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return color(r, g, b)
}

func text(_ ctx: CGContext, _ s: String, at p: CGPoint, font: CTFont = font, color c: CGColor = color(1, 1, 1)) {
    let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: c] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs)!)
    ctx.textPosition = p
    CTLineDraw(line, ctx)
}

var cachedBackground: CGImage?
func background(_ width: Int, _ height: Int) -> CGImage {
    if let b = cachedBackground, b.width == width, b.height == height { return b }
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let gradient = CGGradient(colorsSpace: sRGB, colors: [hsb(0.62, 0.55, 0.35), hsb(0.92, 0.6, 0.18)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
    cachedBackground = ctx.makeImage()!
    return cachedBackground!
}

func render(into buffer: HMBuffer, config c: HMConfigure, time t: Double) {
    IOSurfaceLock(buffer.surface, [], nil)
    defer { IOSurfaceUnlock(buffer.surface, [], nil) }
    guard let ctx = CGContext(
        data: IOSurfaceGetBaseAddress(buffer.surface), width: buffer.width, height: buffer.height,
        bitsPerComponent: 8, bytesPerRow: buffer.bytesPerRow, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return }
    // Points, top-left origin, like the protocol's coordinates.
    let w = Double(buffer.width) / c.scale, h = Double(buffer.height) / c.scale
    ctx.translateBy(x: 0, y: CGFloat(buffer.height))
    ctx.scaleBy(x: c.scale, y: -c.scale)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

    // Background: a gradient, drawn once per size. Drawing it every frame on the CPU
    // costs ~16 ms at retina tile sizes, which would cap the demo, not the compositor.
    ctx.draw(background(buffer.width, buffer.height), in: CGRect(x: 0, y: 0, width: w, height: h))

    // Grid, moved by scrolling.
    ctx.setStrokeColor(color(1, 1, 1, 0.07))
    ctx.setLineWidth(1)
    let step = 40.0
    let ox = state.scroll.x.truncatingRemainder(dividingBy: step), oy = state.scroll.y.truncatingRemainder(dividingBy: step)
    for x in stride(from: ox, through: w, by: step) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)) }
    for y in stride(from: oy, through: h, by: step) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)) }
    ctx.strokePath()

    // A dot orbiting the centre: shows the frame rate at a glance.
    let r = min(w, h) * 0.25
    let dot = CGPoint(x: w / 2 + cos(t * 2) * r, y: h / 2 + sin(t * 2) * r)
    ctx.setFillColor(color(1, 1, 1, 0.8))
    ctx.fillEllipse(in: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12))

    // Pointer.
    if let p = state.pointer {
        ctx.setStrokeColor(color(1, 0.85, 0.3))
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: p.x - 14, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 14, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y - 14)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 14))
        ctx.strokePath()
        if !state.buttons.isEmpty {
            ctx.setFillColor(state.buttons.contains(1) ? color(0.4, 0.7, 1, 0.6) : color(1, 0.5, 0.3, 0.6))
            ctx.fillEllipse(in: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36))
        }
    }

    // Focus ring.
    if state.focused {
        ctx.setStrokeColor(color(0.4, 0.8, 1, 0.9))
        ctx.setLineWidth(3)
        ctx.stroke(CGRect(x: 1.5, y: 1.5, width: w - 3, height: h - 3))
    }

    var y = 44.0
    text(ctx, "Hyprmux demo client", at: CGPoint(x: 24, y: y), font: titleFont); y += 30
    let lines = [
        String(format: "%.0f×%.0f pt @%.0fx  (%d×%d px)   %.0f fps   frame %d", w, h, c.scale, buffer.width, buffer.height, state.fps, state.frames),
        "states: \(c.states.sorted().joined(separator: ", ").isEmpty ? "—" : c.states.sorted().joined(separator: ", "))",
        "pointer: \(state.pointer.map { String(format: "%.0f, %.0f", $0.x, $0.y) } ?? "outside")   buttons: \(state.buttons.sorted().map(String.init).joined(separator: ",").isEmpty ? "—" : state.buttons.sorted().map(String.init).joined(separator: ","))",
        String(format: "scroll: %.0f, %.0f", state.scroll.x, state.scroll.y),
        "last: \(state.lastKey)",
        "typed: \(state.typed)▏",
    ]
    for line in lines { text(ctx, line, at: CGPoint(x: 24, y: y)); y += 22 }
}

dispatchMain()
