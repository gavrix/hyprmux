// Per-surface frame timings for HM_QML_STATS=FILE: the host appends one JSON line
// per surface per second, which scripts/qml-bench.sh reads. Recording is cheap,
// so it's always on; only the writing needs the variable.
#pragma once

#include <QtCore/QJsonObject>
#include <QtCore/QString>

#include <vector>

namespace hm {

/// Durations in milliseconds, summarized as avg, p95, and max.
class Samples {
public:
    void add(double ms) { values_.push_back(ms); }
    size_t count() const { return values_.size(); }
    /// {n, avg, p95, max}, or just {n: 0}. Rounded to 0.01 ms.
    QJsonObject summary() const;
    void clear() { values_.clear(); }

private:
    std::vector<double> values_;
};

struct FrameStats {
    /// Polish, sync, and render: recording the frame on the CPU.
    Samples render;
    /// QQuickRenderControl::endFrame: submitting it. For an offscreen frame, QRhi
    /// waits there for the GPU to finish it.
    Samples submit;
    /// QRhi::finish after that: any GPU wait endFrame left.
    Samples gpuWait;
    /// From one commit to the next.
    Samples interval;
    /// From a commit to its frame callback: how long Hyprmux took to show it.
    Samples callback;
    /// From a configure (a resize) to the commit that answers it.
    Samples configure;
    /// Renders skipped because every buffer was still in Hyprmux's hands.
    int starved = 0;
    /// Configures received.
    int configures = 0;

    /// The line for this second, and a fresh start for the next.
    QJsonObject take();
};

} // namespace hm
