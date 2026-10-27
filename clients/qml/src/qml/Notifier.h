// A QObject with one slot that runs a closure, so a QML property's notify
// signal can reach plain C++ code (QObject::connect wants a QMetaMethod slot).
#pragma once

#include <QtCore/QMetaMethod>
#include <QtCore/QObject>

#include <functional>

namespace hm {

class Notifier : public QObject {
    Q_OBJECT
public:
    std::function<void()> callback;

    /// Calls `callback` whenever `property` of `object` changes. False when it has
    /// no notify signal.
    bool watch(QObject *object, const char *property);

public Q_SLOTS:
    void fire() { if (callback) callback(); }
};

} // namespace hm
