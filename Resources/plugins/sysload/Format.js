// Number formats and the colors that mean calm, busy, and hot, shared by the bar
// and the details.
.pragma library

const calm = "#5ccf7f"
const busy = "#ffc94a"
const hot = "#ff6b63"

function memory(bytes) {
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + " GB"
    return Math.round(bytes / 1048576) + " MB"
}

function percent(p) { return p >= 10 ? Math.round(p) + "%" : p.toFixed(1) + "%" }

// A graph's color levels for a warning threshold: green while calm, amber when
// busy, red at the threshold, blended in between.
function levels(warn) {
    return [{ value: 0, color: calm }, { value: warn * 0.3, color: calm },
            { value: warn * 0.7, color: busy }, { value: warn, color: hot }]
}
