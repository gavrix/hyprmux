// Delivers Hyprmux's input events for one surface to its offscreen Qt Quick window,
// the way a Qt platform plugin would, and reports back what Hyprmux needs to know:
// the cursor shape, and whether the focused item takes text (for input methods).
#pragma once

#include <QtCore/QMetaObject>
#include <QtCore/QPointF>
#include <QtCore/QRect>
#include <QtCore/QString>
#include <QtCore/Qt>

#include <cstdint>
#include <string>

class QQuickWindow;

namespace hm {

class Connection;
struct Event;

class InputBridge {
public:
    InputBridge(QQuickWindow *window, Connection *connection, uint64_t surface);
    ~InputBridge();

    /// `pointer.*` events, in surface points.
    void pointer(const std::string &op, const Event &e);
    /// `keyboard.key` and `keyboard.modifiers`.
    void key(const Event &e);
    /// `keyboard.enter` and `keyboard.leave`.
    void focus(bool in);
    /// `text_input.*`: an input method's preedit and commits, applied at `done`.
    void textInput(const Event &e);
    bool isFocused() const { return focused_; }
    /// Where the pointer last was over the surface, in points: where a context menu
    /// opens by default.
    QPointF pointerPosition() const { return pointer_; }
    /// The surface is about to go: turn text input off while it still exists, and
    /// send nothing about it after.
    void shutdown();
    /// The surface went away (a popup closed): no button is held any more.
    void reset() { pressed_ = {}; }

private:
    void scroll(const Event &e);
    void gesture(const Event &e);
    void updateCursor();
    /// Turns Hyprmux's input method on while the focused item takes text, and keeps
    /// its candidate window next to the caret.
    void updateTextInput();

    QQuickWindow *window_;
    Connection *conn_;
    uint64_t surface_;
    Qt::MouseButtons pressed_;
    QPointF pointer_;
    Qt::CursorShape cursor_ = Qt::ArrowCursor;
    bool focused_ = false;
    bool gone_ = false;

    // Text input: what Hyprmux was told, and the update being assembled.
    bool imEnabled_ = false;
    QRect imCursor_;
    QString preedit_, commit_;
    int preeditBegin_ = -1, preeditEnd_ = -1;
    int deleteBefore_ = 0, deleteAfter_ = 0;
    QMetaObject::Connection focusObjectWatch_, cursorWatch_;
};

} // namespace hm
