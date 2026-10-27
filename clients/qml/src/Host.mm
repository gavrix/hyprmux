#include "Host.h"

#include "Trace.h"
#include "protocol/Connection.h"
#include "qml/BarItem.h"
#include "qml/BarPopup.h"
#include "qml/HyprmuxApp.h"
#include "qml/HyprmuxWindow.h"
#include "qml/Plugin.h"
#include "qml/System.h"
#include "qml/Theme.h"
#include "qml/Tiles.h"
#include "scene/Scene.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QFileSystemWatcher>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QTimer>
#include <QtQml/QQmlComponent>
#include <QtQml/QJSEngine>
#include <QtQml/QQmlEngine>

#include <algorithm>
#include <cstdio>

namespace hm {

Host &Host::get() {
    static Host *host = new Host();   // lives for the process: QML holds pointers into it
    return *host;
}

Host::Host() : plugin_(std::make_unique<Plugin>(nullptr)) {}
Host::~Host() = default;

bool Host::isPlugin() const { return !plugin_->id().isEmpty(); }

bool Host::allowed(const char *permission) const {
    return !isPlugin() || plugin_->permissions().contains(QString::fromLatin1(permission));
}

/// Singletons Qt mustn't delete: the host owns them.
template <typename T> static T *keep(T *o) {
    QJSEngine::setObjectOwnership(o, QJSEngine::CppOwnership);
    return o;
}

static void deny(QJSEngine *js, const char *type, const char *permission) {
    if (js) js->throwError(QStringLiteral("%1 needs the \"%2\" permission in plugin.json").arg(type, permission));
}

System *Host::system(QJSEngine *js) {
    if (!allowed("system-stats")) { deny(js, "System", "system-stats"); return nullptr; }
    if (!system_) system_ = std::make_unique<System>(nullptr);
    return keep(system_.get());
}

Tiles *Host::tiles(QJSEngine *js) {
    if (!allowed("tiles")) { deny(js, "Tiles", "tiles"); return nullptr; }
    if (!tiles_) tiles_ = std::make_unique<Tiles>(conn_);
    return keep(tiles_.get());
}

HyprmuxApp *HyprmuxApp::create(QQmlEngine *, QJSEngine *) { return Host::get().app(); }

HyprmuxApp *Host::app() {
    if (!app_) app_ = std::make_unique<HyprmuxApp>(nullptr);
    return keep(app_.get());
}

bool Host::offerWindows(const QByteArray &windowsJSON) {
    if (answering_.empty() || !conn_) return false;
    Message m("launch.offer");
    m.str("launch_token", answering_).str("windows_json", windowsJSON.toStdString());
    conn_->send(m);
    return true;
}

void HyprmuxApp::offer(const QVariantList &windows) {
    QJsonArray list;
    for (const QVariant &v : windows) {
        QVariantMap w = v.toMap();
        list.append(QJsonObject{{"id", w.value("id").toString()}, {"title", w.value("title").toString()},
                                {"detail", w.value("detail").toString()}});
    }
    if (Host::get().offerWindows(QJsonDocument(list).toJson(QJsonDocument::Compact))) offered_ = true;
    else std::fprintf(stderr, "hyprmux-qml: HyprmuxApp.offer() works only in onLaunched\n");
}

Theme *Host::theme() {
    if (!theme_) theme_ = std::make_unique<Theme>(nullptr);
    return keep(theme_.get());
}

void Host::setConnection(Connection *c) {
    conn_ = c;
    HM_TRACE("theme from welcome: %s", c->welcomeTheme().c_str());
    theme()->apply(QByteArray::fromStdString(c->welcomeTheme()));
    auto waiting = std::move(waiting_);
    for (HyprmuxWindow *w : waiting) openWindow(w);
}

void Host::addScene(std::unique_ptr<Scene> s) {
    if (s) scenes_.push_back(std::move(s));
}

bool Host::showRoot(QQuickItem *root, const QString &file, QString *error) {
    if (auto *bar = qobject_cast<BarItem *>(root)) {
        auto scene = Scene::barItem(conn_, bar, error);
        if (!scene) return false;
        // A bar item's popups render in surfaces of their own.
        std::vector<BarPopup *> popups = scene->barPopups();
        Scene &item = *scene;
        addScene(std::move(scene));
        for (BarPopup *p : popups) addScene(Scene::popup(conn_, p, item));
        return true;
    }
    auto scene = Scene::toplevel(conn_, root, nullptr, QFileInfo(file).completeBaseName(), error);
    if (!scene) return false;
    addScene(std::move(scene));
    return true;
}

void Host::windowCreated(HyprmuxWindow *w) {
    if (!conn_) { waiting_.push_back(w); return; }
    openWindow(w);
}

void Host::windowCompleted(HyprmuxWindow *w) {
    for (auto &s : scenes_) {
        if (s->window() != w) continue;
        s->reclaim();
        s->createToplevel();
    }
}

void Host::openWindow(HyprmuxWindow *w) {
    // A reload: the window takes over a tile the old file's windows left.
    if (!orphans_.empty()) {
        Scene *s = orphans_.front();
        orphans_.erase(orphans_.begin());
        s->adopt(w, w);
        return;
    }
    QString error;
    auto scene = Scene::toplevel(conn_, w, w, QString(), &error);
    if (!scene) { std::fprintf(stderr, "hyprmux-qml: %s\n", qPrintable(error)); return; }
    addScene(std::move(scene));
}

void Host::windowDestroyed(HyprmuxWindow *w) {
    waiting_.erase(std::remove(waiting_.begin(), waiting_.end(), w), waiting_.end());
    for (auto it = scenes_.begin(); it != scenes_.end(); ++it) {
        if ((*it)->window() != w) continue;
        if (reloading_ && (*it)->isOpenToplevel()) {
            (*it)->orphan();
            orphans_.push_back(it->get());
            return;
        }
        bool open = (*it)->isOpenToplevel();
        scenes_.erase(it);
        if (open) toplevelClosed();
        return;
    }
}

bool Host::load(QQmlEngine *engine, const QString &file, QString *error) {
    engine_ = engine;
    file_ = file;
    root_ = create(error);
    if (!root_) return false;
    if (qEnvironmentVariableIntValue("HM_QML_RELOAD")) watchForReload();
    return true;
}

/// Makes the file's root. HyprmuxWindows announce themselves while it loads; any
/// other root is shown here.
QObject *Host::create(QString *error) {
    QQmlComponent component(engine_, QUrl::fromLocalFile(QFileInfo(file_).absoluteFilePath()));
    QObject *root = component.create();
    if (!root) {
        QStringList lines;
        for (const QQmlError &err : component.errors()) lines << err.toString();
        *error = lines.join('\n');
        return nullptr;
    }
    if (!qobject_cast<HyprmuxWindow *>(root)) {
        auto *item = qobject_cast<QQuickItem *>(root);
        if (!item) {
            *error = "the root of " + QFileInfo(file_).fileName() + " must be a HyprmuxWindow, an Item, or a BarItem, not a Window";
            delete root;
            return nullptr;
        }
        // On a reload, a plain root takes over the tile it had.
        for (auto &s : scenes_) {
            if (reloading_ && s->role() == Scene::Role::Toplevel && !s->window() && s->isOpenToplevel()) {
                s->adopt(item, nullptr);
                return root;
            }
        }
        if (!showRoot(item, QFileInfo(file_).fileName(), error)) { delete root; return nullptr; }
    }
    return root;
}

/// HM_QML_RELOAD=1: the file's folder, and folders under it, reload the app on save.
void Host::watchForReload() {
    auto *watcher = new QFileSystemWatcher(QCoreApplication::instance());
    auto *debounce = new QTimer(watcher);
    debounce->setSingleShot(true);
    debounce->setInterval(150);   // editors write a file in several steps
    auto rewatch = [this, watcher] {
        QDir dir = QFileInfo(file_).absoluteDir();
        QStringList paths{dir.absolutePath()};
        for (const QFileInfo &f : dir.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot)) paths << f.absoluteFilePath();
        for (const QString &p : paths)
            if (!watcher->files().contains(p) && !watcher->directories().contains(p)) watcher->addPath(p);
    };
    rewatch();
    QObject::connect(watcher, &QFileSystemWatcher::fileChanged, debounce, qOverload<>(&QTimer::start));
    QObject::connect(watcher, &QFileSystemWatcher::directoryChanged, debounce, qOverload<>(&QTimer::start));
    QObject::connect(debounce, &QTimer::timeout, watcher, [this, rewatch] { rewatch(); reload(); });
}

void Host::reload() {
    std::fprintf(stderr, "hyprmux-qml: reloading %s\n", qPrintable(QFileInfo(file_).fileName()));
    reloading_ = true;
    engine_->clearComponentCache();
    // A plain root stays until the new one takes its tile; windows go now and leave
    // their tiles waiting.
    if (qobject_cast<HyprmuxWindow *>(root_)) delete root_;
    QString error;
    root_ = create(&error);
    if (!root_) std::fprintf(stderr, "%s\n", qPrintable(error));
    // The new windows open on the next turn (windowCreated); tiles left over after
    // that belonged to windows the new file doesn't have.
    QMetaObject::invokeMethod(QCoreApplication::instance(), [this] {
        QMetaObject::invokeMethod(QCoreApplication::instance(), [this] {
            reloading_ = false;
            auto left = std::move(orphans_);
            for (Scene *s : left)
                scenes_.erase(std::remove_if(scenes_.begin(), scenes_.end(), [s](auto &p) { return p.get() == s; }), scenes_.end());
            if (!left.empty()) toplevelClosed();
        }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
}

void Host::toplevelClosed() {
    if (reloading_) return;
    if (isPlugin()) return;
    bool any = std::any_of(scenes_.begin(), scenes_.end(), [](auto &s) { return s->isOpenToplevel(); });
    if (!any) QCoreApplication::quit();
}

Scene *Host::tileFor(QObject *object) const {
    // Up the item tree first (a menu in a list delegate), then up the object tree
    // (a dialog declared in a window).
    for (QObject *o = object; o; o = o->parent()) {
        QQuickItem *item = qobject_cast<QQuickItem *>(o);
        for (; item; item = item->parentItem()) {
            for (auto &s : scenes_)
                if (s->isOpenToplevel() && item->window() == s->quickWindow()) return s.get();
        }
        if (auto *w = qobject_cast<HyprmuxWindow *>(o))
            for (auto &s : scenes_) if (s->window() == w && s->isOpenToplevel()) return s.get();
    }
    for (auto &s : scenes_) if (s->isOpenToplevel()) return s.get();
    return nullptr;
}

uint64_t Host::expectReply(Reply reply) {
    uint64_t id = conn_->allocate();
    replies_[id] = std::move(reply);
    return id;
}

bool Host::handle(const Event &e) {
    if (e.op() == "dialog.result" || e.op() == "menu.selected") {
        auto it = replies_.find(e.u64("id"));
        if (it == replies_.end()) return false;
        Reply reply = std::move(it->second);
        replies_.erase(it);
        reply(e);
        return true;
    }
    if (e.op() == "launch") {
        // Why Hyprmux started us: arguments, and on a restore, the windows to bring
        // back. The app opens them in `launched`; then the launch is answered.
        std::string token = e.str("launch_token");
        QStringList args, tokens;
        xpc_object_t a = xpc_dictionary_get_value(e.dict, "args");
        if (a && xpc_get_type(a) == XPC_TYPE_ARRAY)
            for (size_t i = 0; i < xpc_array_get_count(a); i++) args << QString::fromUtf8(xpc_array_get_string(a, i));
        xpc_object_t t = xpc_dictionary_get_value(e.dict, "restore_tokens");
        if (t && xpc_get_type(t) == XPC_TYPE_ARRAY)
            for (size_t i = 0; i < xpc_array_get_count(t); i++) tokens << QString::fromUtf8(xpc_array_get_string(t, i));
        HM_TRACE("launch: %lld args, %lld restore tokens", (long long)args.size(), (long long)tokens.size());
        answering_ = token;
        app()->setLaunch(args, tokens);
        answering_.clear();
        // An offer waits for the pick. Otherwise the windows opened in `launched`
        // are complete now: say there are no more, so Hyprmux drops restored
        // tiles the app didn't bring back.
        if (!app()->takeOffered()) {
            Message done("launch.done");
            done.str("launch_token", token);
            conn_->send(done);
        }
        return true;
    }
    if (e.op() == "launch.open") {
        std::string token = e.str("launch_token");
        answering_ = token;
        emit app()->openRequested(QString::fromStdString(e.str("window")));
        answering_.clear();
        Message done("launch.done");
        done.str("launch_token", token);
        conn_->send(done);
        return true;
    }
    if (e.op() == "launch.cancel") return true;   // nobody waits; nothing to undo
    if (e.op() == "theme.changed") {
        theme()->apply(QByteArray::fromStdString(e.str("theme_json")));
        return true;
    }
    if (tiles_ && tiles_->handle(e)) return true;
    // A copy: handling an event can open or close windows.
    std::vector<Scene *> scenes;
    for (auto &s : scenes_) scenes.push_back(s.get());
    for (Scene *s : scenes) if (s->handle(e)) return true;
    return false;
}

} // namespace hm
