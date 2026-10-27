#include "Notifier.h"

#include <QtCore/QMetaProperty>

namespace hm {

bool Notifier::watch(QObject *object, const char *property) {
    const QMetaObject *meta = object->metaObject();
    int index = meta->indexOfProperty(property);
    if (index < 0) return false;
    QMetaProperty p = meta->property(index);
    if (!p.hasNotifySignal()) return false;
    QMetaMethod slot = metaObject()->method(metaObject()->indexOfSlot("fire()"));
    return QObject::connect(object, p.notifySignal(), this, slot);
}

} // namespace hm
