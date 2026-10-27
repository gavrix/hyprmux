// `BarItem`: the root of a QML scene that lives in Hyprmux's workspace bar.
//
//   import Hyprmux
//   BarItem {
//       implicitWidth: label.implicitWidth + 16   // the width it asks for
//       Text { id: label; anchors.centerIn: parent; text: "CPU 12%" }
//   }
//
// The bar sets the height and grants the width, up to its maximum.
#pragma once

#include <QtQml/qqmlregistration.h>
#include <QtQuick/QQuickItem>

namespace hm {

class BarItem : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    /// Where in the bar: only "right" for now.
    Q_PROPERTY(QString slot READ slot WRITE setSlot NOTIFY slotChanged)
    /// Lower comes first, left to right.
    Q_PROPERTY(int order READ order WRITE setOrder NOTIFY orderChanged)

public:
    using QQuickItem::QQuickItem;

    QString slot() const { return slot_; }
    void setSlot(const QString &s) { if (s != slot_) { slot_ = s; emit slotChanged(); } }
    int order() const { return order_; }
    void setOrder(int o) { if (o != order_) { order_ = o; emit orderChanged(); } }

signals:
    void slotChanged();
    void orderChanged();

private:
    QString slot_ = QStringLiteral("right");
    int order_ = 0;
};

} // namespace hm
