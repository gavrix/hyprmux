// Translates Hyprmux input events (AppKit values) into Qt's.
#pragma once

#include <QtCore/QString>
#include <QtCore/Qt>
#include <QtGui/QCursor>

#include <cstdint>

namespace hm {

/// `NSEvent.ModifierFlags` to Qt modifiers, with Qt's macOS convention:
/// Command is ControlModifier and Control is MetaModifier.
Qt::KeyboardModifiers qtModifiers(uint64_t flags);

/// `NSEvent.pressedMouseButtons` (bit 0 left, 1 right, 2 middle) to Qt buttons.
Qt::MouseButtons qtButtons(uint64_t pressed);

/// A protocol button number (0 left, 1 right, 2 middle, 3+ others) to a Qt button.
Qt::MouseButton qtButton(uint64_t button);

/// A macOS virtual key code to a Qt key. `ignoringModifiers` is
/// `charactersIgnoringModifiers`, for keys the code alone doesn't name.
int qtKey(uint16_t keyCode, const QString &ignoringModifiers);

/// The text a key event carries: `characters`, minus AppKit's function-key
/// private-use characters and control characters.
QString qtKeyText(const QString &characters);

/// A Qt cursor shape to a protocol cursor name.
const char *cursorName(Qt::CursorShape shape);

} // namespace hm
