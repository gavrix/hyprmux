// `BarPopup`: a panel that drops from its bar item.
//
//   BarItem {
//       TapHandler { onTapped: details.open = !details.open }
//       BarPopup {
//           id: details
//           implicitWidth: 420; implicitHeight: list.implicitHeight
//           Column { id: list; ... }
//       }
//   }
//
// It is declared inside the BarItem but renders in its own surface: the host moves
// it out of the bar's scene. Its implicit size is the size it asks for. Hyprmux
// closes it on a click elsewhere or Esc, which sets `open` to false.
#pragma once

#include <QtQml/qqmlregistration.h>
#include <QtQuick/QQuickItem>

namespace hm {

class BarPopup : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool open READ isOpen WRITE setOpen NOTIFY openChanged)

public:
    using QQuickItem::QQuickItem;

    bool isOpen() const { return open_; }
    void setOpen(bool o) { if (o != open_) { open_ = o; emit openChanged(); } }

signals:
    void openChanged();

private:
    bool open_ = false;
};

} // namespace hm
