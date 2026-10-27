// Conversions between Qt's dialog and menu conventions and the protocol's
// (docs/CLIENT_PROTOCOL.md, section 7). No window system: tested on their own.
#pragma once

#include <QtCore/QJsonArray>
#include <QtCore/QString>
#include <QtCore/QStringList>

namespace hm {

/// Qt's name filters ("Text (*.txt *.md)") as the protocol's
/// `[{name: "Text", extensions: ["txt", "md"]}]`. `*` and `*.*` become "*", any file.
QJsonArray dialogFilters(const QStringList &nameFilters);

/// Qt's shortcut text ("Ctrl+Shift+N", where Ctrl is ⌘) as the accelerator
/// Hyprmux shows ("Cmd+Shift+N"). Qt's Meta, the Control key, becomes Ctrl.
QString menuAccelerator(const QString &shortcut);

} // namespace hm
