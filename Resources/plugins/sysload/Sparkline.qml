// A small line graph, newest at the right edge: the last `span` seconds of a value.
//
// Colored by value, not by position: each point takes the color of the level it
// reached, so a calm stretch reads green, a busy one amber, a hot one red, with
// the same thresholds the numbers use. A flat line at the top of a graph scaled to
// its own peak stays green when the value itself is calm.
import QtQuick

Canvas {
    id: graph
    /// The samples, oldest first.
    property var values: []
    /// Each sample's time in seconds before now (0 or less), as `values`. Empty:
    /// one every `step` seconds, the last one now.
    property var times: []
    property real step: 2
    /// Seconds the width covers.
    property real span: 300
    /// The value at the top. 0: the largest sample. Larger values clip.
    property real maximum: 0
    /// Colors by value, lowest first: [{value, color}], blended in between. Empty:
    /// `color` throughout.
    property var levels: []
    property color color: "white"
    /// Shade the area under the line.
    property bool filled: true

    implicitWidth: 48
    implicitHeight: 14

    onValuesChanged: requestPaint()
    onLevelsChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    /// The levels' color at `v`, blended between the two levels around it.
    function colorAt(v) {
        if (levels.length === 0) return graph.color
        if (v <= levels[0].value) return levels[0].color
        for (let i = 1; i < levels.length; i++) {
            const a = levels[i - 1], b = levels[i]
            if (v <= b.value) return Qt.tint(a.color, Qt.alpha(b.color, (v - a.value) / (b.value - a.value)))
        }
        return levels[levels.length - 1].color
    }

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        const n = values.length
        if (n < 2 || width <= 0 || height <= 0) return
        let top = maximum > 0 ? maximum : Math.max(...values)
        if (!(top > 0)) top = 1
        const timed = times.length === n
        const pad = 1   // keep the stroke inside the canvas
        const ys = v => pad + (height - 2 * pad) * (1 - Math.min(v, top) / top)

        // A vertical gradient whose stops sit where each level's value falls on this
        // graph's scale. Levels above the top don't show: the top takes the color its
        // own value has, so a calm graph scaled to its peak stays calm.
        let ink = graph.color
        if (levels.length > 0) {
            const g = ctx.createLinearGradient(0, height - pad, 0, pad)
            for (const l of levels) if (l.value < top) g.addColorStop(l.value / top, l.color)
            g.addColorStop(1, colorAt(top))
            ink = g
        }

        let firstX = 0, lastX = 0
        ctx.beginPath()
        for (let i = 0; i < n; i++) {
            const t = timed ? times[i] : -(n - 1 - i) * step
            const x = Math.max(0, width * (1 + t / span))
            const y = ys(values[i])
            if (i === 0) { ctx.moveTo(x, y); firstX = x } else ctx.lineTo(x, y)
            lastX = x
        }
        ctx.lineWidth = 1.25
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        ctx.strokeStyle = ink
        ctx.stroke()

        if (filled) {
            ctx.lineTo(lastX, height)
            ctx.lineTo(firstX, height)
            ctx.closePath()
            ctx.globalAlpha = 0.22
            ctx.fillStyle = ink
            ctx.fill()
            ctx.globalAlpha = 1
        }
    }
}
