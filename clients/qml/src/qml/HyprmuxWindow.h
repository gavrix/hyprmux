// `HyprmuxWindow`: a window of a QML app, shown as a Hyprmux tile.
//
//   import QtQuick
//   import Hyprmux
//
//   HyprmuxWindow {
//       title: "Notes"
//       onClosing: close => close.accepted = !unsaved   // "Save changes?" first
//       TextArea { anchors.fill: parent }
//   }
//
// Every HyprmuxWindow that exists is a tile: the file's root, one declared inside
// another, or one made later (`Component.createObject`). Hyprmux sizes it. The app
// quits when its last window closes.
#pragma once

#include <QtGui/QColor>
#include <QtQml/qqmlregistration.h>
#include <QtQuick/QQuickItem>

namespace hm {

/// What `closing` hands the app: set `accepted` to false to keep the window open.
class WindowClose : public QObject {
    Q_OBJECT
    QML_ANONYMOUS
    Q_PROPERTY(bool accepted MEMBER accepted)
public:
    bool accepted = true;
};

class HyprmuxWindow : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    /// The tile's title.
    Q_PROPERTY(QString title READ title WRITE setTitle NOTIFY titleChanged)
    /// What shows behind the content. By default Hyprmux's own background, as
    /// terminals have: `Theme.background`. `"transparent"` to draw it all yourself.
    Q_PROPERTY(QColor color READ color WRITE setColor RESET resetColor NOTIFY colorChanged)
    /// The tile has the keyboard.
    Q_PROPERTY(bool active READ isActive NOTIFY activeChanged)
    /// Names this window across restarts. Hyprmux saves it with the tile; when it
    /// restores the session, it relaunches the app with the tokens it saved
    /// (`HyprmuxApp.restoreTokens`), and the window that has a token goes back into
    /// that token's tile. Up to 4 KiB.
    Q_PROPERTY(QString restoreToken READ restoreToken WRITE setRestoreToken NOTIFY restoreTokenChanged)

public:
    explicit HyprmuxWindow(QQuickItem *parent = nullptr);
    ~HyprmuxWindow() override;

    QString title() const { return title_; }
    void setTitle(const QString &t);
    QColor color() const;
    void setColor(const QColor &c);
    void resetColor();
    bool hasColor() const { return color_.isValid(); }
    bool isActive() const { return active_; }
    /// Its properties are set: it may ask for its tile.
    bool isComplete() const { return isComponentComplete(); }
    void setActive(bool a);
    QString restoreToken() const { return restoreToken_; }
    void setRestoreToken(const QString &t) { if (t != restoreToken_) { restoreToken_ = t; emit restoreTokenChanged(); } }

    /// Closes the tile, without asking `closing` first.
    Q_INVOKABLE void close();
    /// Asks Hyprmux to focus the tile. It does only right after the user pressed
    /// something in this app, so a window can't steal focus.
    Q_INVOKABLE void activate();

signals:
    void titleChanged();
    void colorChanged();
    void activeChanged();
    void restoreTokenChanged();
    /// The user asked to close the tile (its close bind, the context menu).
    void closing(hm::WindowClose *close);
    /// The tile is gone.
    void closed();
    /// For the host: close() and activate() were called.
    void closeRequestedByApp();
    void activateRequested();

protected:
    /// The tile opens here, before the window's children exist: they're made inside
    /// its scene, so they (popups and dialogs too) inherit its palette from the start.
    void classBegin() override;
    void componentComplete() override;

private:
    QString title_, restoreToken_;
    QColor color_;
    bool active_ = false;
};

} // namespace hm
