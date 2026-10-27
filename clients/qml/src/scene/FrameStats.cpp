#include "FrameStats.h"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace hm {

static double round2(double v) { return std::round(v * 100) / 100; }

QJsonObject Samples::summary() const {
    if (values_.empty()) return QJsonObject{{"n", 0}};
    std::vector<double> v = values_;
    std::sort(v.begin(), v.end());
    double avg = std::accumulate(v.begin(), v.end(), 0.0) / double(v.size());
    // Nearest rank: the smallest value at or above 95% of the samples.
    size_t rank = size_t(std::ceil(0.95 * double(v.size())));
    double p95 = v[std::min(v.size(), std::max<size_t>(rank, 1)) - 1];
    return QJsonObject{{"n", int(v.size())}, {"avg", round2(avg)}, {"p95", round2(p95)}, {"max", round2(v.back())}};
}

QJsonObject FrameStats::take() {
    QJsonObject o{{"frames", int(render.count())}, {"render", render.summary()}, {"submit", submit.summary()},
                  {"gpu_wait", gpuWait.summary()},
                  {"interval", interval.summary()}, {"callback", callback.summary()},
                  {"configure", configure.summary()}, {"configures", configures}, {"starved", starved}};
    render.clear(); submit.clear(); gpuWait.clear(); interval.clear(); callback.clear(); configure.clear();
    starved = 0;
    configures = 0;
    return o;
}

} // namespace hm
