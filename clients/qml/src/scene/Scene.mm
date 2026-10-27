#include "Scene.h"

#include "../Host.h"
#include "../Trace.h"
#include "../protocol/Connection.h"
#include "../qml/BarItem.h"
#include "../qml/BarPopup.h"
#include "../qml/HyprmuxWindow.h"
#include "../qml/Theme.h"
#include "../qml/Notifier.h"
#include "../render/Swapchain.h"
#include "InputBridge.h"

#import <Metal/Metal.h>

#include <QtCore/QCoreApplication>
#include <QtCore/QPointer>
#include <QtCore/QFileInfo>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlEngine>
#include <QtQuick/QQuickGraphicsDevice>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickRenderControl>
#include <QtQuick/QQuickWindow>
#include <rhi/qrhi.h>

#include <cmath>
#include <string>

namespace hm {

struct Scene::Impl {
    Connection *conn = nullptr;
    Role kind = Role::Toplevel;
    /// The role object: the toplevel, bar item, or popup. A popup gets a new one each
    /// time it opens; 0 while it's closed.
    uint64_t role = 0, surface = 0;
    /// A popup's bar item.
    uint64_t parentItem = 0;
    /// The size last asked for, in points: a bar item's width, a popup's size.
    QSizeF asked = QSizeF(-1, -1);

    QQuickRenderControl *control = nullptr;
    QQuickWindow *window = nullptr;
    QQuickItem *root = nullptr;
    /// Adopted roots (popups) belong to the bar's QML tree, not to this scene.
    bool ownsRoot = true;
    std::unique_ptr<Swapchain> swapchain;
    std::unique_ptr<InputBridge> input;

    QSizeF points;
    double scale = 2;
    QSize pixels;
    bool configured = false;
    uint64_t serial = 0;
    bool unacked = false;

    /// The scene changed since the last frame.
    bool dirty = true;
    /// A frame callback is outstanding. Hyprmux sends none while the surface is hidden,
    /// so the scene stops rendering there by itself.
    bool waitingFrame = false;
    bool renderQueued = false;
    uint64_t frameCallback = 0;

    QString title;
    Notifier titleWatch;
    /// The window a tile shows, when it's a HyprmuxWindow.
    QPointer<HyprmuxWindow> appWindow;
    /// The tile closed: by the user, the app, or the window going away.
    bool closed = false;

    const char *prefix() const {
        return kind == Role::BarItem ? "bar_item" : kind == Role::Popup ? "popup" : "toplevel";
    }

    ~Impl() {
        if (kind == Role::Toplevel && !closed && conn) destroyToplevel();
        if (!ownsRoot && root) root->setParentItem(nullptr);
        else delete root;
        input.reset();
        delete window;
        delete control;
    }

    /// The offscreen window the scene renders in, on the shared Metal device, and the
    /// surface Hyprmux shows it on.
    bool setUp(Connection *connection) {
        conn = connection;
        control = new QQuickRenderControl();
        window = new QQuickWindow(control);
        window->setColor(Qt::transparent);
        window->setGraphicsDevice(QQuickGraphicsDevice::fromDeviceAndCommandQueue(
            (MTLDevice *)(__bridge id)metalDevice(), (MTLCommandQueue *)(__bridge id)metalQueue()));
        if (!control->initialize()) return false;
        // A native window that's never shown: Qt counts a window active only when it
        // has one and is the focus window, and Qt Quick Controls match shortcuts
        // (`Shortcut`, `Action`) only in active windows. It isn't drawn into: the
        // render control draws into Hyprmux's surfaces.
        window->create();
        swapchain = std::make_unique<Swapchain>(conn);
        surface = conn->allocate();
        Message s("surface.create");
        s.u64("id", surface);
        conn->send(s);
        input = std::make_unique<InputBridge>(window, conn, surface);
        QObject::connect(control, &QQuickRenderControl::renderRequested, control, [this] { scheduleRender(); });
        QObject::connect(control, &QQuickRenderControl::sceneChanged, control, [this] { scheduleRender(); });
        return true;
    }

    // MARK: Rendering

    void scheduleRender() {
        dirty = true;
        if (waitingFrame || renderQueued) return;
        renderQueued = true;
        QMetaObject::invokeMethod(control, [this] {
            renderQueued = false;
            if (dirty && !waitingFrame) render();
        }, Qt::QueuedConnection);
    }

    void render() {
        if (!configured || pixels.isEmpty()) return;
        Buffer *b = swapchain->acquire(pixels, scale);
        if (!b) {   // all busy: draw again on the next release
            dirty = true;
            HM_TRACE("%s: no free buffer", prefix());
            return;
        }
        dirty = false;
        window->setRenderTarget(b->target);
        control->polishItems();
        control->beginFrame();
        control->sync();
        control->render();
        control->endFrame();
        // The protocol has no fence: Hyprmux may read the IOSurface as soon as the
        // commit arrives, so the GPU has to be done with it first.
        control->rhi()->finish();
        dumpFrame(b, prefix());

        if (unacked) {
            Message ack((std::string(prefix()) + ".ack_configure").c_str());
            ack.u64("id", role).u64("serial", serial);
            conn->send(ack);
            unacked = false;
        }
        frameCallback = conn->allocate();
        Message attach("surface.attach");
        attach.u64("id", surface).u64("buffer", b->id);
        conn->send(attach);
        Message setScale("surface.set_scale");
        setScale.u64("id", surface).f64("scale", scale);
        conn->send(setScale);
        Message frame("surface.frame");
        frame.u64("id", surface).u64("callback", frameCallback);
        conn->send(frame);
        Message commit("surface.commit");
        commit.u64("id", surface);
        conn->send(commit);
        b->busy = true;
        waitingFrame = true;
        HM_TRACE("%s: committed %dx%d in buffer %llu", prefix(), pixels.width(), pixels.height(), (unsigned long long)b->id);
    }

    // MARK: Protocol events

    void configure(const Event &e) {
        double w = e.f64("w"), h = e.f64("h"), s = e.f64("scale");
        if (w <= 0 || h <= 0) {   // "choose your size"
            w = points.width() > 0 ? points.width() : 800;
            h = points.height() > 0 ? points.height() : 600;
        }
        scale = s > 0 ? s : conn->welcomeScale();
        points = QSizeF(w, h);
        pixels = QSize(int(std::lround(w * scale)), int(std::lround(h * scale)));
        serial = e.u64("serial");
        unacked = true;
        HM_TRACE("%s: configure %llu, %.0fx%.0f @%.0fx", prefix(), (unsigned long long)serial, w, h, scale);
        window->setGeometry(0, 0, int(std::ceil(w)), int(std::ceil(h)));
        window->contentItem()->setSize(points);
        root->setSize(points);
        swapchain->retireStale(pixels, scale);
        configured = true;
        // Answer a configure at once, even mid-frame: a resize shouldn't wait a refresh.
        render();
    }

    void frameDone() {
        waitingFrame = false;
        if (dirty) render();
    }

    void setTitle(const QString &t) {
        if (kind != Role::Toplevel || t == title || t.isEmpty()) return;
        title = t;
        if (!created) return;   // sent with createToplevel
        Message m("toplevel.set_title");
        m.u64("id", role).str("title", t.toStdString());
        conn->send(m);
    }

    /// A bar item asks for its implicit width, a popup for its implicit size, rounded
    /// up to whole points.
    void askSize(bool force = false) {
        if (role == 0) return;
        QSizeF size(std::ceil(root->implicitWidth()), kind == Role::Popup ? std::ceil(root->implicitHeight()) : 0);
        if (size == asked && !force) return;
        asked = size;
        if (kind == Role::BarItem) {
            Message m("bar_item.set_width");
            m.u64("id", role).f64("w", size.width());
            conn->send(m);
        } else if (kind == Role::Popup) {
            Message m("popup.set_size");
            m.u64("id", role).f64("w", size.width()).f64("h", size.height());
            conn->send(m);
        }
    }

    // MARK: Tiles

    bool created = false;

    void createToplevel() {
        if (created || closed) return;
        created = true;
        Message t("toplevel.create");
        t.u64("id", role).u64("surface", surface);
        if (HyprmuxWindow *w = appWindow.data(); w && !w->restoreToken().isEmpty())
            t.str("restore_token", w->restoreToken().toStdString());
        // Opened for a launch of an app already running: it lands where that
        // launch started.
        if (const std::string &launch = Host::get().answeringLaunch(); !launch.empty()) t.str("launch_token", launch);
        conn->send(t);
        // The title set before the tile existed.
        QString t0 = title;
        title.clear();
        setTitle(t0);
    }

    void sendRestoreToken() {
        HyprmuxWindow *w = appWindow.data();
        if (!created || closed || !w) return;
        Message m("toplevel.set_restore_token");
        m.u64("id", role).str("token", w->restoreToken().toStdString());
        conn->send(m);
    }

    void destroyToplevel() {
        if (input) input->shutdown();
        Message t("toplevel.destroy");
        t.u64("id", role);
        conn->send(t);
        Message s("surface.destroy");
        s.u64("id", surface);
        conn->send(s);
        closed = true;
        configured = false;
    }

    /// Closes the tile for good. A window made at run time (JavaScript owns it) goes
    /// too; the file's own windows stay objects, closed.
    void closeToplevel() {
        if (closed) return;
        HM_TRACE("toplevel %llu closes", (unsigned long long)role);
        destroyToplevel();
        if (HyprmuxWindow *w = appWindow.data()) {
            emit w->closed();
            if (QQmlEngine::objectOwnership(w) == QQmlEngine::JavaScriptOwnership) w->deleteLater();
        }
        Host::get().toplevelClosed();
    }

    /// `toplevel.close_requested`: the app may say no (`closing`, `accepted = false`).
    void closeRequested() {
        if (HyprmuxWindow *w = appWindow.data()) {
            WindowClose close;
            emit w->closing(&close);
            if (!close.accepted) return;
        }
        closeToplevel();
    }

    /// Shows `newRoot` in this tile: at creation, and again after a live reload, which
    /// keeps the tile and swaps what's in it.
    void attach(QQuickItem *newRoot, HyprmuxWindow *w, const QString &fallbackTitle) {
        if (root && root != newRoot) {   // a plain root the reload replaced
            if (ownsRoot) delete root; else root->setParentItem(nullptr);
        }
        root = newRoot;
        ownsRoot = w == nullptr;
        appWindow = w;
        root->setParentItem(window->contentItem());
        if (configured) root->setSize(points);
        Impl *p = this;
        // Controls take Hyprmux's colors, and follow them: set on the window, so
        // popups and dialogs (in its overlay, not under the root) get them too.
        Theme *theme = Host::get().theme();
        theme->style(window);
        QObject::connect(theme, &Theme::changed, control, [p, theme] { theme->style(p->window); });
        if (w) {
            window->setColor(w->color());
            QObject::connect(w, &HyprmuxWindow::colorChanged, control, [p, w] { p->window->setColor(w->color()); });
            setTitle(w->title().isEmpty() ? QCoreApplication::applicationName() : w->title());
            QObject::connect(w, &HyprmuxWindow::titleChanged, control, [p, w] { p->setTitle(w->title()); });
            QObject::connect(w, &HyprmuxWindow::closeRequestedByApp, control, [p] { p->closeToplevel(); });
            QObject::connect(w, &HyprmuxWindow::activateRequested, control, [p] { p->activate(); });
            QObject::connect(w, &HyprmuxWindow::restoreTokenChanged, control, [p] { p->sendRestoreToken(); });
            if (input) w->setActive(input->isFocused());
        } else {
            window->setColor(Qt::transparent);
            // The root's `title` property names the tile, else the file does.
            QString title = root->property("title").toString();
            setTitle(title.isEmpty() ? fallbackTitle : title);
            titleWatch.callback = [p] { p->setTitle(p->root->property("title").toString()); };
            titleWatch.watch(root, "title");
        }
        scheduleRender();
    }

    void activate() {
        Message m("toplevel.request_activate");
        m.u64("id", role).u64("activation_token", Host::get().activationSerial());
        // While answering a launch, the launch itself allows it: the user opened the app.
        if (const std::string &launch = Host::get().answeringLaunch(); !launch.empty()) m.str("launch_token", launch);
        conn->send(m);
    }

    // MARK: Popups

    void openPopup() {
        if (role != 0) return;
        role = conn->allocate();
        HM_TRACE("popup %llu opens", (unsigned long long)role);
        Message m("popup.create");
        m.u64("id", role).u64("surface", surface).u64("parent", parentItem);
        conn->send(m);
        askSize(true);
    }

    void closePopup() {
        if (role == 0) return;
        HM_TRACE("popup %llu closes", (unsigned long long)role);
        Message m("popup.destroy");
        m.u64("id", role);
        conn->send(m);
        role = 0;
        // Hyprmux released its buffers and answers no more callbacks for it.
        configured = false;
        waitingFrame = false;
        unacked = false;
        swapchain->markAllFree();
        input->reset();
    }
};

Scene::Scene(std::unique_ptr<Impl> impl) : d(std::move(impl)) {}
Scene::~Scene() = default;

Scene::Role Scene::role() const { return d->kind; }
HyprmuxWindow *Scene::window() const { return d->appWindow.data(); }
void Scene::adopt(QQuickItem *root, HyprmuxWindow *window) { d->attach(root, window, d->title); }
void Scene::createToplevel() { d->createToplevel(); }

void Scene::reclaim() {
    if (d->root && d->root->parentItem() != d->window->contentItem()) {
        d->root->setParentItem(d->window->contentItem());
        if (d->configured) d->root->setSize(d->points);
    }
}

void Scene::orphan() {
    if (d->ownsRoot) delete d->root;
    d->root = nullptr;
    d->appWindow = nullptr;
}
bool Scene::isOpenToplevel() const { return d->kind == Role::Toplevel && !d->closed; }
uint64_t Scene::surfaceID() const { return d->surface; }
QPointF Scene::pointerPosition() const { return d->input ? d->input->pointerPosition() : QPointF(); }
QQuickWindow *Scene::quickWindow() const { return d->window; }

std::unique_ptr<Scene> Scene::toplevel(Connection *connection, QQuickItem *root, HyprmuxWindow *window,
                                       const QString &fallbackTitle, QString *error) {
    auto d = std::make_unique<Impl>();
    if (!d->setUp(connection)) {
        *error = "Qt Quick couldn't initialize Metal";
        return nullptr;
    }
    d->role = connection->allocate();
    d->attach(root, window, fallbackTitle);
    // A window still being made (its properties aren't set) asks for its tile once
    // it's complete (Host::windowCompleted): its restore token goes with the request.
    if (!window || window->isComplete()) d->createToplevel();
    return std::unique_ptr<Scene>(new Scene(std::move(d)));
}

std::unique_ptr<Scene> Scene::barItem(Connection *connection, BarItem *root, QString *error) {
    auto d = std::make_unique<Impl>();
    if (!d->setUp(connection)) {
        *error = "Qt Quick couldn't initialize Metal";
        return nullptr;
    }
    Impl *p = d.get();
    d->kind = Role::BarItem;
    d->root = root;
    root->setParentItem(d->window->contentItem());
    d->role = connection->allocate();
    Message b("bar_item.create");
    b.u64("id", d->role).u64("surface", d->surface).str("slot", root->slot().toStdString());
    xpc_dictionary_set_int64(b.raw(), "order", root->order());
    connection->send(b);
    d->askSize();
    QObject::connect(root, &QQuickItem::implicitWidthChanged, d->control, [p] { p->askSize(); });
    return std::unique_ptr<Scene>(new Scene(std::move(d)));
}

std::unique_ptr<Scene> Scene::popup(Connection *connection, BarPopup *popup, const Scene &bar) {
    auto d = std::make_unique<Impl>();
    if (!d->setUp(connection)) return nullptr;
    d->kind = Role::Popup;
    d->parentItem = bar.d->role;
    d->root = popup;
    d->ownsRoot = false;
    popup->setParentItem(d->window->contentItem());
    Impl *p = d.get();
    auto sync = [p, popup] { if (popup->isOpen()) p->openPopup(); else p->closePopup(); };
    QObject::connect(popup, &BarPopup::openChanged, d->control, sync);
    QObject::connect(popup, &QQuickItem::implicitWidthChanged, d->control, [p] { p->askSize(); });
    QObject::connect(popup, &QQuickItem::implicitHeightChanged, d->control, [p] { p->askSize(); });
    sync();
    return std::unique_ptr<Scene>(new Scene(std::move(d)));
}

std::vector<BarPopup *> Scene::barPopups() const {
    std::vector<BarPopup *> out;
    if (d->kind != Role::BarItem || !d->root) return out;
    for (QQuickItem *child : d->root->childItems())
        if (auto *p = qobject_cast<BarPopup *>(child)) out.push_back(p);
    return out;
}

bool Scene::handle(const Event &e) {
    std::string op = e.op();
    if (op == "bar_item.configure" || op == "popup.configure") {
        Role kind = op == "popup.configure" ? Role::Popup : Role::BarItem;
        if (d->kind != kind || d->role == 0 || e.u64("id") != d->role) return false;
        d->configure(e);
        return true;
    }
    if (op == "popup.dismissed") {
        if (d->kind != Role::Popup || d->role == 0 || e.u64("id") != d->role) return false;
        static_cast<BarPopup *>(d->root)->setOpen(false);   // closePopup destroys the role
        return true;
    }
    if (op == "toplevel.configure" || op == "toplevel.close_requested") {
        if (d->kind != Role::Toplevel || d->closed || e.u64("id") != d->role) return false;
        if (op == "toplevel.configure") d->configure(e);
        else d->closeRequested();
        return true;
    }
    if (op == "surface.frame_done") {
        if (e.u64("callback") != d->frameCallback) return false;
        d->frameDone();
        return true;
    }
    if (op == "buffer.release") {
        if (!d->swapchain->release(e.u64("id"))) return false;
        if (d->dirty && !d->waitingFrame) d->render();
        return true;
    }
    if (e.u64("surface") != d->surface) return false;
    // A press can ask for focus later (`activate()`): remember its serial.
    if (op == "pointer.button" && e.hasString("state", "down")) Host::get().notePress(e.u64("serial"));
    if (op == "keyboard.key" && e.hasString("state", "down")) Host::get().notePress(e.u64("serial"));
    if (op.rfind("pointer.", 0) == 0) {
        if (op != "pointer.motion") HM_TRACE("%s: %s", d->prefix(), op.c_str());
        d->input->pointer(op, e);
    } else if (op == "keyboard.enter" || op == "keyboard.leave") {
        bool in = op == "keyboard.enter";
        d->input->focus(in);
        if (HyprmuxWindow *w = d->appWindow.data()) w->setActive(in);
    } else if (op == "keyboard.key" || op == "keyboard.modifiers") {
        d->input->key(e);
    } else if (op.rfind("text_input.", 0) == 0) {
        d->input->textInput(e);
    } else {
        return false;
    }
    return true;
}

} // namespace hm
