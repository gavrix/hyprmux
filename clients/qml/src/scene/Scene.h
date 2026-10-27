// One QML scene shown as one Hyprmux surface: a tile (a HyprmuxWindow, or a plain
// Item root), a slot in the workspace bar (a BarItem), or a popup under one (a
// BarPopup inside a BarItem).
#pragma once

#include <QtCore/QPointF>
#include <QtCore/QString>

#include <cstdint>
#include <QtCore/QUrl>

#include <memory>
#include <vector>

class QQuickItem;
class QQuickWindow;

namespace hm {

class BarItem;
class BarPopup;
class HyprmuxWindow;
class Connection;
struct Event;

class Scene {
public:
    enum class Role { Toplevel, BarItem, Popup };

    /// A tile showing `root`. With `window`, the tile is that HyprmuxWindow's (`root`
    /// is the window): its title, close, and focus. Without, `root` is a plain Item
    /// the scene owns, titled by its `title` property or `fallbackTitle`.
    static std::unique_ptr<Scene> toplevel(Connection *connection, QQuickItem *root, HyprmuxWindow *window,
                                           const QString &fallbackTitle, QString *error);
    /// A slot in the workspace bar.
    static std::unique_ptr<Scene> barItem(Connection *connection, BarItem *root, QString *error);
    /// A popup that drops from `bar`'s item. It opens and closes with `popup.open`.
    static std::unique_ptr<Scene> popup(Connection *connection, BarPopup *popup, const Scene &bar);

    ~Scene();
    Scene(const Scene &) = delete;
    Scene &operator=(const Scene &) = delete;

    Role role() const;
    /// The HyprmuxWindow a tile shows. Null for other scenes.
    HyprmuxWindow *window() const;
    /// A tile that's still open.
    bool isOpenToplevel() const;
    /// The surface's protocol id: what dialogs and menus are shown over.
    uint64_t surfaceID() const;
    /// Where the pointer last was over it, in points.
    QPointF pointerPosition() const;
    /// The offscreen window the scene renders: items in it belong to this tile.
    QQuickWindow *quickWindow() const;
    /// A live reload: the tile shows `root` (`window`, if it's a HyprmuxWindow) now.
    void adopt(QQuickItem *root, HyprmuxWindow *window);
    /// Asks Hyprmux for the tile, if a window still being made deferred it.
    void createToplevel();
    /// Puts the window back in this scene, if QML moved it into another (a window
    /// declared inside a window).
    void reclaim();
    /// A live reload deleted what the tile showed; it waits for the new one.
    void orphan();
    /// Routes a protocol event. False when it isn't for this scene.
    bool handle(const Event &e);
    /// A bar item's popups, still inside its scene: give each a Scene of its own.
    std::vector<BarPopup *> barPopups() const;

    struct Impl;

private:
    explicit Scene(std::unique_ptr<Impl> d);
    std::unique_ptr<Impl> d;
};

} // namespace hm
