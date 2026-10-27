#include "KeyMap.h"

namespace hm {

// NSEvent.ModifierFlags raw values.
static const uint64_t kShift = 1 << 17, kControl = 1 << 18, kOption = 1 << 19, kCommand = 1 << 20,
                      kNumericPad = 1 << 21;

Qt::KeyboardModifiers qtModifiers(uint64_t f) {
    Qt::KeyboardModifiers m;
    if (f & kShift) m |= Qt::ShiftModifier;
    if (f & kControl) m |= Qt::MetaModifier;
    if (f & kOption) m |= Qt::AltModifier;
    if (f & kCommand) m |= Qt::ControlModifier;
    if (f & kNumericPad) m |= Qt::KeypadModifier;
    return m;
}

Qt::MouseButtons qtButtons(uint64_t pressed) {
    Qt::MouseButtons b;
    if (pressed & 1) b |= Qt::LeftButton;
    if (pressed & 2) b |= Qt::RightButton;
    if (pressed & 4) b |= Qt::MiddleButton;
    if (pressed & 8) b |= Qt::BackButton;
    if (pressed & 16) b |= Qt::ForwardButton;
    return b;
}

Qt::MouseButton qtButton(uint64_t button) {
    switch (button) {
    case 0: return Qt::LeftButton;
    case 1: return Qt::RightButton;
    case 2: return Qt::MiddleButton;
    case 3: return Qt::BackButton;
    case 4: return Qt::ForwardButton;
    default: return Qt::ExtraButton4;
    }
}

int qtKey(uint16_t code, const QString &ignoring) {
    switch (code) {
    case 0x24: return Qt::Key_Return;
    case 0x4C: return Qt::Key_Enter;
    case 0x30: return Qt::Key_Tab;
    case 0x31: return Qt::Key_Space;
    case 0x33: return Qt::Key_Backspace;
    case 0x35: return Qt::Key_Escape;
    case 0x75: return Qt::Key_Delete;
    case 0x7B: return Qt::Key_Left;
    case 0x7C: return Qt::Key_Right;
    case 0x7D: return Qt::Key_Down;
    case 0x7E: return Qt::Key_Up;
    case 0x73: return Qt::Key_Home;
    case 0x77: return Qt::Key_End;
    case 0x74: return Qt::Key_PageUp;
    case 0x79: return Qt::Key_PageDown;
    case 0x38: case 0x3C: return Qt::Key_Shift;
    case 0x3B: case 0x3E: return Qt::Key_Meta;     // Control, by Qt's macOS convention
    case 0x3A: case 0x3D: return Qt::Key_Alt;
    case 0x37: case 0x36: return Qt::Key_Control;  // Command
    case 0x39: return Qt::Key_CapsLock;
    case 0x7A: return Qt::Key_F1;
    case 0x78: return Qt::Key_F2;
    case 0x63: return Qt::Key_F3;
    case 0x76: return Qt::Key_F4;
    case 0x60: return Qt::Key_F5;
    case 0x61: return Qt::Key_F6;
    case 0x62: return Qt::Key_F7;
    case 0x64: return Qt::Key_F8;
    case 0x65: return Qt::Key_F9;
    case 0x6D: return Qt::Key_F10;
    case 0x67: return Qt::Key_F11;
    case 0x6F: return Qt::Key_F12;
    default: break;
    }
    if (ignoring.isEmpty()) return Qt::Key_unknown;
    // Qt's keys for printable characters are their upper-case code points.
    QChar c = ignoring.at(0).toUpper();
    return c.unicode();
}

QString qtKeyText(const QString &characters) {
    QString out;
    for (QChar c : characters) {
        ushort u = c.unicode();
        if (u >= 0xF700 && u <= 0xF8FF) continue;   // NSUpArrowFunctionKey and friends
        if (u < 0x20 && u != '\r' && u != '\t') continue;
        if (u == 0x7F) continue;
        out.append(c);
    }
    return out;
}

const char *cursorName(Qt::CursorShape shape) {
    // Every Qt shape. Bitmap cursors (Qt::BitmapCursor) aren't sent: the arrow.
    switch (shape) {
    case Qt::IBeamCursor: return "ibeam";
    case Qt::PointingHandCursor: return "pointing_hand";
    case Qt::CrossCursor: return "crosshair";
    case Qt::OpenHandCursor: return "open_hand";
    case Qt::ClosedHandCursor: return "closed_hand";
    case Qt::SizeHorCursor: case Qt::SplitHCursor: return "resize_left_right";
    case Qt::SizeVerCursor: case Qt::SplitVCursor: return "resize_up_down";
    case Qt::UpArrowCursor: return "resize_up";
    case Qt::SizeFDiagCursor: return "resize_nwse";
    case Qt::SizeBDiagCursor: return "resize_nesw";
    case Qt::SizeAllCursor: return "move";
    case Qt::DragCopyCursor: return "copy";
    case Qt::DragLinkCursor: return "link";
    case Qt::DragMoveCursor: return "closed_hand";
    case Qt::WhatsThisCursor: return "help";
    case Qt::WaitCursor: return "wait";
    case Qt::BusyCursor: return "progress";
    case Qt::ForbiddenCursor: return "not_allowed";
    case Qt::BlankCursor: return "hidden";
    default: return "arrow";
    }
}

} // namespace hm
