// The animation driver: Qt Quick animations advance on Hyprmux's frame callbacks
// instead of Qt's 16 ms timer.
//
// - They step once per frame Hyprmux shows, at the display's rate (120 Hz on
//   ProMotion), with the time of the frame they're drawn for.
// - Hyprmux sends no callbacks for a hidden surface. When no surface of the process
//   shows, animations pause, and their bindings stop running.
// - While one runs, every shown surface draws every frame, as in Qt's own render
//   loops. A change Qt Quick doesn't report, such as an effect's hidden source
//   moving, then still reaches the screen.
#pragma once

#include <QtCore/QAbstractAnimation>

#include <functional>

namespace hm {

qint64 hostClockMs();

class FrameDriver : public QAnimationDriver {
    Q_OBJECT

public:
    /// `kick` asks every shown surface for a frame: animations just started.
    explicit FrameDriver(std::function<void()> kick) : kick_(std::move(kick)) {}

    /// A frame callback arrived, for a frame shown at `time` (CACurrentMediaTime
    /// seconds; 0 when Hyprmux didn't say). Several surfaces' callbacks for the same
    /// frame advance animations once.
    void frame(double time);

    qint64 elapsed() const override;

protected:
    void start() override;
    void stop() override;

private:
    std::function<void()> kick_;
    /// Animation time in ms since start() (`base_`, on the host clock).
    qint64 time_ = 0;
    qint64 base_ = 0;
    double lastFrame_ = 0;
};

/// The host's clock, in ms: CACurrentMediaTime, the clock Hyprmux's frame times use.
qint64 hostClockMs();

} // namespace hm
