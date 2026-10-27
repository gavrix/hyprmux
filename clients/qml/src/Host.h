// The host process's shared state: the connection, the plugin it runs (if any),
// its scenes (one per surface), and the `Hyprmux` QML singletons, made when QML
// first uses them.
#pragma once

#include <QtCore/QString>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <vector>

class QJSEngine;
class QObject;
class QQmlEngine;
class QQuickItem;

namespace hm {

class Connection;
class HyprmuxApp;
class HyprmuxWindow;
class Plugin;
class Scene;
class System;
class Theme;
class Tiles;
struct Event;

class Host {
public:
    /// The one host. Set up in main, before any QML loads.
    static Host &get();

    /// Connected: theme from the welcome, and windows made before now get their tiles.
    void setConnection(Connection *c);
    Connection *connection() const { return conn_; }

    /// The plugin being run. Its id is empty when the host runs a bare QML file.
    Plugin *plugin() const { return plugin_.get(); }
    bool isPlugin() const;

    /// Whether the scene may use what `permission` guards: a plugin needs it in its
    /// manifest; a bare QML file (an app, a test) may use everything.
    bool allowed(const char *permission) const;

    /// The singletons. Null, with a JavaScript error thrown into `js`, when the
    /// plugin lacks the permission.
    System *system(QJSEngine *js);
    Tiles *tiles(QJSEngine *js);
    Theme *theme();
    HyprmuxApp *app();

    /// Loads the app or plugin file and shows it: its HyprmuxWindows, or its root (a bar
    /// item, or an Item as a tile). With HM_QML_RELOAD=1, loads it again on every save,
    /// keeping the tiles. False, with `error` set, when it doesn't load.
    bool load(QQmlEngine *engine, const QString &file, QString *error);
    /// HyprmuxWindows announce themselves; each becomes a tile.
    void windowCreated(HyprmuxWindow *w);
    void windowCompleted(HyprmuxWindow *w);
    void windowDestroyed(HyprmuxWindow *w);
    /// A tile closed. The app quits when no tile is left.
    void toplevelClosed();

    /// The serial of the user's last press in any of this app's surfaces: what lets
    /// a window ask for focus (`toplevel.request_activate`).
    uint64_t activationSerial() const { return activationSerial_; }
    void notePress(uint64_t serial) { if (serial) activationSerial_ = serial; }

    /// The open tile `object` is in: the window it's declared in, or the one whose
    /// scene its item is in. Else the first open tile. Null without one.
    Scene *tileFor(QObject *object) const;

    /// Sends a request that Hyprmux answers with an event naming the same `id`
    /// (`dialog.result`, `menu.selected`). `reply` runs with that event, once.
    using Reply = std::function<void(const Event &)>;
    uint64_t expectReply(Reply reply);

    /// The launch being answered while the app opens its windows for it: their
    /// toplevels name it, so they land in the launch's place. Empty otherwise.
    const std::string &answeringLaunch() const { return answering_; }
    /// Offers the windows of the launch being answered (HyprmuxApp.offer).
    bool offerWindows(const QByteArray &windowsJSON);

    /// Routes an event to whoever it's for. False when nothing took it.
    bool handle(const Event &e);

private:
    Host();
    ~Host();
    void addScene(std::unique_ptr<Scene> s);
    void openWindow(HyprmuxWindow *w);
    bool showRoot(QQuickItem *root, const QString &file, QString *error);
    QObject *create(QString *error);
    void watchForReload();
    void reload();

    Connection *conn_ = nullptr;
    std::unique_ptr<Plugin> plugin_;
    std::unique_ptr<System> system_;
    std::unique_ptr<Tiles> tiles_;
    std::unique_ptr<Theme> theme_;
    std::unique_ptr<HyprmuxApp> app_;
    std::vector<std::unique_ptr<Scene>> scenes_;
    std::vector<HyprmuxWindow *> waiting_;
    QQmlEngine *engine_ = nullptr;
    QString file_;
    QObject *root_ = nullptr;
    /// Tiles a reload emptied, waiting for the reloaded windows.
    std::vector<Scene *> orphans_;
    bool reloading_ = false;
    uint64_t activationSerial_ = 0;
    std::map<uint64_t, Reply> replies_;
    std::string answering_;
};

} // namespace hm
