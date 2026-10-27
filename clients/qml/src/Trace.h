// HM_QML_DEBUG=1: timings and events on stderr, for debugging the host.
#pragma once

#include <QtCore/QElapsedTimer>

#include <cstdio>
#include <cstdlib>

namespace hm {

inline bool tracing() {
    static const bool on = std::getenv("HM_QML_DEBUG") != nullptr;
    return on;
}

inline double traceClock() {
    static QElapsedTimer t;
    if (!t.isValid()) t.start();
    return double(t.nsecsElapsed()) / 1e6;
}

} // namespace hm

#define HM_TRACE(...) do { if (hm::tracing()) { std::fprintf(stderr, "[%8.1f ms] ", hm::traceClock()); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); } } while (0)
