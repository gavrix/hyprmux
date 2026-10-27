// `NativeMenu`: a macOS menu that Hyprmux shows over the app's tile, like other
// apps' context menus (docs/CLIENT_PROTOCOL.md, section 7). Qt Quick Controls'
// `Menu` still works, drawn inside the tile.
//
//   NativeMenu {
//       id: rowMenu
//       NativeMenuItem { text: "Rename"; onTriggered: rename() }
//       NativeMenuSeparator {}
//       NativeMenuItem { text: "Delete"; shortcut: "Ctrl+Backspace"; onTriggered: remove() }
//   }
//   TapHandler { acceptedButtons: Qt.RightButton; onTapped: rowMenu.popup() }
#pragma once

#include <QtCore/QObject>
#include <QtCore/QPointF>
#include <QtCore/QVariant>
#include <QtQml/QQmlListProperty>
#include <QtQml/qqmlregistration.h>

#include <QtCore/QJsonArray>

namespace hm {

class NativeMenuItem : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString text MEMBER text_ NOTIFY changed)
    Q_PROPERTY(bool enabled MEMBER enabled_ NOTIFY changed)
    Q_PROPERTY(bool checkable MEMBER checkable_ NOTIFY changed)
    Q_PROPERTY(bool checked MEMBER checked_ NOTIFY checkedChanged)
    /// Shown next to the text, in Qt's form: "Ctrl+S" is ⌘S. Only shown: the
    /// shortcut itself is a `Shortcut`'s or an `Action`'s.
    Q_PROPERTY(QString shortcut MEMBER shortcut_ NOTIFY changed)

public:
    using QObject::QObject;
    QString text() const { return text_; }
    bool isEnabled() const { return enabled_; }
    bool isCheckable() const { return checkable_; }
    bool isChecked() const { return checked_; }
    QString shortcut() const { return shortcut_; }
    /// The user picked it: toggles a checkable item, then `triggered`.
    void trigger();

signals:
    void changed();
    void checkedChanged();
    void triggered();

private:
    QString text_, shortcut_;
    bool enabled_ = true, checkable_ = false, checked_ = false;
};

class NativeMenuSeparator : public QObject {
    Q_OBJECT
    QML_ELEMENT
public:
    using QObject::QObject;
};

class NativeMenu : public QObject {
    Q_OBJECT
    QML_ELEMENT
    /// A submenu's text, when it's inside another NativeMenu.
    Q_PROPERTY(QString title MEMBER title_ NOTIFY changed)
    Q_PROPERTY(bool enabled MEMBER enabled_ NOTIFY changed)
    Q_PROPERTY(QQmlListProperty<QObject> data READ data)
    Q_CLASSINFO("DefaultProperty", "data")

public:
    using QObject::QObject;
    QQmlListProperty<QObject> data();

    /// Shows the menu: where the pointer last was over the tile, or at `x`, `y` in
    /// `item`'s coordinates (the menu's parent item when `item` is null).
    Q_INVOKABLE void popup(QObject *item = nullptr, qreal x = qQNaN(), qreal y = qQNaN());

signals:
    void changed();
    /// It closed, with or without a pick.
    void closed();

private:
    QJsonArray items(QHash<QString, NativeMenuItem *> &ids) const;

    QString title_;
    bool enabled_ = true;
    QList<QObject *> data_;
};

} // namespace hm
