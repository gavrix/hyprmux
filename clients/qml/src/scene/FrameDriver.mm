#include "FrameDriver.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>

namespace hm {

qint64 hostClockMs() { return qint64(CACurrentMediaTime() * 1000); }

qint64 FrameDriver::elapsed() const {
    // Qt's animation timer adds this to the time it started the driver: ms since
    // start(), frozen between frames.
    return isRunning() ? time_ : 0;
}

void FrameDriver::start() {
    base_ = hostClockMs();
    time_ = 0;
    lastFrame_ = 0;
    QAnimationDriver::start();
    if (kick_) kick_();
}

void FrameDriver::stop() { QAnimationDriver::stop(); }

void FrameDriver::frame(double time) {
    if (!isRunning()) return;
    double now = CACurrentMediaTime();
    double at = time > 0 ? time : now;
    // The same frame, from another surface's callback.
    if (lastFrame_ > 0 && at - lastFrame_ < 0.002) return;
    lastFrame_ = at;
    // Never backwards, and never more than a frame ahead of now.
    time_ = std::max(time_, std::min(qint64(at * 1000), qint64(now * 1000) + 17) - base_);
    advance();
}

} // namespace hm
