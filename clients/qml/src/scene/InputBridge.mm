#include "InputBridge.h"

#include "../Trace.h"
#include "../protocol/Connection.h"
#include "KeyMap.h"

#include <QtCore/QCoreApplication>
#include <QtGui/QGuiApplication>
#include <QtGui/QInputMethod>
#include <QtGui/QInputMethodEvent>
#include <QtGui/QKeyEvent>
#include <QtGui/QTextCharFormat>
#include <QtGui/qpa/qwindowsysteminterface.h>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>

#include <cmath>

namespace hm {

// Input goes through Qt's window-system queue, as a platform plugin delivers it, not
// sendEvent: pointer handlers (TapHandler, HoverHandler) track points per device,
// shortcuts (`Shortcut`, `Action.shortcut`) match there, and only that path does
// both. main() makes the queue synchronous, so events arrive in order, at once.
using WSI = QWindowSystemInterface;

InputBridge::InputBridge(QQuickWindow *window, Connection *connection, uint64_t surface)
    : window_(window), conn_(connection), surface_(surface) {
    focusObjectWatch_ = QObject::connect(window_, &QQuickWindow::focusObjectChanged, window_, [this] { updateTextInput(); });
    cursorWatch_ = QObject::connect(QGuiApplication::inputMethod(), &QInputMethod::cursorRectangleChanged, window_,
                                    [this] { if (focused_) updateTextInput(); });
}

InputBridge::~InputBridge() {
    QObject::disconnect(focusObjectWatch_);
    QObject::disconnect(cursorWatch_);
}

void InputBridge::pointer(const std::string &op, const Event &e) {
    QPointF p(e.f64("x"), e.f64("y"));
    if (op != "pointer.leave") pointer_ = p;
    Qt::KeyboardModifiers mods = qtModifiers(e.u64("modifiers"));
    if (op == "pointer.enter") {
        WSI::handleEnterEvent(window_, p, p);
    } else if (op == "pointer.leave") {
        WSI::handleLeaveEvent(window_);
    } else if (op == "pointer.motion") {
        WSI::handleMouseEvent(window_, p, p, pressed_, Qt::NoButton, QEvent::MouseMove, mods);
    } else if (op == "pointer.button") {
        Qt::MouseButton button = qtButton(e.u64("button"));
        bool down = e.hasString("state", "down");
        if (down) pressed_ |= button; else pressed_ &= ~button;
        WSI::handleMouseEvent(window_, p, p, pressed_, button,
                              down ? QEvent::MouseButtonPress : QEvent::MouseButtonRelease, mods);
    } else if (op == "pointer.scroll") {
        scroll(e);
    } else if (op == "pointer.gesture") {
        gesture(e);
    }
    updateCursor();
}

void InputBridge::scroll(const Event &e) {
    QPointF p(e.f64("x"), e.f64("y"));
    double dx = e.f64("dx"), dy = e.f64("dy");
    uint64_t phase = e.u64("phase"), momentum = e.u64("momentum_phase");
    // NSEvent.Phase: began 1, stationary 2, changed 4, ended 8, cancelled 16, mayBegin 32.
    Qt::ScrollPhase qphase = Qt::NoScrollPhase;
    if (momentum) qphase = (momentum & (8 | 16)) ? Qt::ScrollEnd : Qt::ScrollMomentum;
    else if (phase & 1) qphase = Qt::ScrollBegin;
    else if (phase & (2 | 4)) qphase = Qt::ScrollUpdate;
    else if (phase & (8 | 16)) qphase = Qt::ScrollEnd;
    else if (phase & 32) return;

    QPoint pixelDelta, angleDelta;
    if (e.boolean("precise")) {
        pixelDelta = QPoint(int(std::lround(dx)), int(std::lround(dy)));
        angleDelta = pixelDelta * 2;
    } else {
        // Lines: a notch is 120 eighths of a degree in Qt's units.
        double tx = e.f64("ticks_x"), ty = e.f64("ticks_y");
        angleDelta = QPoint(int(std::lround((tx != 0 ? tx : dx) * 120)), int(std::lround((ty != 0 ? ty : dy) * 120)));
    }
    WSI::handleWheelEvent(window_, 0, p, p, pixelDelta, angleDelta, qtModifiers(e.u64("modifiers")), qphase);
}

/// The trackpad, for pinch and rotate: PinchHandler and friends take native
/// gestures from a touchpad device only.
static const QPointingDevice *trackpad() {
    static QPointingDevice *device = [] {
        auto *d = new QPointingDevice(QStringLiteral("Hyprmux trackpad"), 0x4859524d, QInputDevice::DeviceType::TouchPad,
                                      QPointingDevice::PointerType::Finger, QInputDevice::Capability::Position, 5, 0);
        QWindowSystemInterface::registerInputDevice(d);
        return d;
    }();
    return device;
}

void InputBridge::gesture(const Event &e) {
    QPointF p(e.f64("x"), e.f64("y"));
    ulong time = ulong(e.f64("time") * 1000);
    uint64_t phase = e.u64("phase");
    bool rotate = e.hasString("kind", "rotate");
    // NSEvent.Phase: began 1, changed 4, ended 8, cancelled 16. Qt wants a begin,
    // the changes, and an end around them.
    if (phase & 1) WSI::handleGestureEvent(window_, time, trackpad(), Qt::BeginNativeGesture, p, p, 2);
    if (double v = e.f64("value"); v != 0)
        WSI::handleGestureEventWithRealValue(window_, time, trackpad(),
                                             rotate ? Qt::RotateNativeGesture : Qt::ZoomNativeGesture,
                                             rotate ? -v : v, p, p, 2);   // Qt's rotation is clockwise
    if (phase & (8 | 16)) WSI::handleGestureEvent(window_, time, trackpad(), Qt::EndNativeGesture, p, p, 2);
}

void InputBridge::key(const Event &e) {
    uint64_t flags = e.u64("modifiers");
    if (e.op() == "keyboard.modifiers") {
        // Qt tracks modifiers through key events; nothing to send on their own.
        return;
    }
    uint16_t code = uint16_t(e.u64("key_code"));
    bool down = e.hasString("state", "down");
    QString chars = QString::fromStdString(e.str("characters"));
    QString ignoring = QString::fromStdString(e.str("characters_ignoring_modifiers"));
    int qkey = qtKey(code, ignoring);
    Qt::KeyboardModifiers mods = qtModifiers(flags);
    // Command and Control chords carry no text, as from Qt's own Cocoa windows: a text
    // field would otherwise claim ⌘⇧N as typing and keep it from its shortcut.
    QString text = (mods & (Qt::ControlModifier | Qt::MetaModifier)) ? QString() : qtKeyText(chars);
    bool repeat = e.boolean("repeat");
    ulong time = ulong(e.f64("time") * 1000);
    // A shortcut takes the press first, as on Qt's own windows.
    if (down && WSI::handleShortcutEvent(window_, time, qkey, mods, code, code, quint32(flags), text, repeat)) {
        HM_TRACE("key 0x%x: a shortcut took it", unsigned(qkey));
        return;
    }
    if (down) HM_TRACE("key 0x%x mods 0x%x \"%s\", focus window %s", unsigned(qkey), unsigned(mods.toInt()), qPrintable(text),
                       QGuiApplication::focusWindow() == window_ ? "ours" : QGuiApplication::focusWindow() ? "another" : "none");
    WSI::handleExtendedKeyEvent(window_, time, down ? QEvent::KeyPress : QEvent::KeyRelease, qkey, mods,
                                code, code, quint32(flags), text, repeat);
    if (down) updateTextInput();
}

void InputBridge::focus(bool in) {
    focused_ = in;
    HM_TRACE("keyboard %s", in ? "enter" : "leave");
    // The focus window decides where keys and shortcuts go; with several tiles, the
    // one Hyprmux focuses. Leaving: none, unless another of ours took it already.
    if (in) WSI::handleFocusWindowChanged(window_, Qt::ActiveWindowFocusReason);
    else if (QGuiApplication::focusWindow() == window_) WSI::handleFocusWindowChanged(nullptr, Qt::ActiveWindowFocusReason);
    updateTextInput();
}

void InputBridge::shutdown() {
    if (gone_) return;
    focused_ = false;
    updateTextInput();   // disables it, if it was on
    gone_ = true;
    QObject::disconnect(focusObjectWatch_);
    QObject::disconnect(cursorWatch_);
}

void InputBridge::updateTextInput() {
    if (gone_) return;
    QObject *target = window_->focusObject();
    bool enable = false;
    QRect cursor;
    if (focused_ && target) {
        QInputMethodQueryEvent q(Qt::ImEnabled | Qt::ImCursorRectangle);
        QCoreApplication::sendEvent(target, &q);
        enable = q.value(Qt::ImEnabled).toBool();
        if (enable) {
            QRectF r = q.value(Qt::ImCursorRectangle).toRectF();
            if (auto *item = qobject_cast<QQuickItem *>(target)) r = item->mapRectToScene(r);
            cursor = r.toAlignedRect();
        }
    }
    HM_TRACE("text input: focused %d, focus object %s, takes text %d", focused_,
             target ? target->metaObject()->className() : "none", enable);
    if (enable != imEnabled_) {
        imEnabled_ = enable;
        HM_TRACE("text input %s", enable ? "on" : "off");
        Message m(enable ? "text_input.enable" : "text_input.disable");
        m.u64("surface", surface_);
        // The client draws compositions itself: Qt Quick's text items show preedit.
        if (enable) m.str("preedit", "client");
        conn_->send(m);
        imCursor_ = QRect();
    }
    if (enable && cursor != imCursor_ && cursor.isValid()) {
        imCursor_ = cursor;
        Message m("text_input.set_cursor_rect");
        m.u64("surface", surface_).f64("x", cursor.x()).f64("y", cursor.y()).f64("w", cursor.width()).f64("h", cursor.height());
        conn_->send(m);
    }
}

void InputBridge::textInput(const Event &e) {
    std::string op = e.op();
    if (op == "text_input.preedit") {
        preedit_ = QString::fromStdString(e.str("text"));
        preeditBegin_ = int(e.u64("cursor_begin"));
        preeditEnd_ = int(e.u64("cursor_end"));
    } else if (op == "text_input.commit") {
        commit_ += QString::fromStdString(e.str("text"));
    } else if (op == "text_input.delete_surrounding") {
        deleteBefore_ = int(e.u64("before"));
        deleteAfter_ = int(e.u64("after"));
    } else if (op == "text_input.done") {
        // One atomic update since the last `done`: deletion, commit, the new preedit.
        QList<QInputMethodEvent::Attribute> attrs;
        if (!preedit_.isEmpty()) {
            QTextCharFormat underline;
            underline.setFontUnderline(true);
            attrs << QInputMethodEvent::Attribute(QInputMethodEvent::TextFormat, 0, int(preedit_.size()), underline);
            int caret = preeditBegin_ >= 0 ? preeditBegin_ : int(preedit_.size());
            attrs << QInputMethodEvent::Attribute(QInputMethodEvent::Cursor, caret, 1);
        }
        QInputMethodEvent ev(preedit_, attrs);
        if (!commit_.isEmpty() || deleteBefore_ || deleteAfter_)
            ev.setCommitString(commit_, -deleteBefore_, deleteBefore_ + deleteAfter_);
        if (QObject *target = window_->focusObject()) QCoreApplication::sendEvent(target, &ev);
        HM_TRACE("text input: commit \"%s\", preedit \"%s\"", qPrintable(commit_), qPrintable(preedit_));
        preedit_.clear();
        commit_.clear();
        preeditBegin_ = preeditEnd_ = -1;
        deleteBefore_ = deleteAfter_ = 0;
        updateTextInput();
    }
}

void InputBridge::updateCursor() {
    Qt::CursorShape shape = window_->cursor().shape();
    if (shape == cursor_) return;
    cursor_ = shape;
    Message m("pointer.set_cursor");
    m.str("name", cursorName(shape));
    conn_->send(m);
}

} // namespace hm
