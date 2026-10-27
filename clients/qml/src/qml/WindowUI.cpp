#include "WindowUI.h"

#include <QtCore/QJsonObject>
#include <QtCore/QRegularExpression>
#include <QtGui/QKeySequence>

namespace hm {

QJsonArray dialogFilters(const QStringList &nameFilters) {
    static const QRegularExpression pattern(R"(^\s*(.*?)\s*\(([^)]*)\)\s*$)");
    static const QRegularExpression glob(R"(^\*\.?)");
    QJsonArray out;
    for (const QString &f : nameFilters) {
        auto match = pattern.match(f);
        QString name = match.hasMatch() ? match.captured(1) : f;
        QString globs = match.hasMatch() ? match.captured(2) : f;
        QJsonArray exts;
        for (QString g : globs.split(' ', Qt::SkipEmptyParts)) {
            g.remove(glob);
            exts.append(g.isEmpty() || g == "*" ? QStringLiteral("*") : g);
        }
        out.append(QJsonObject{{"name", name}, {"extensions", exts}});
    }
    return out;
}

QString menuAccelerator(const QString &shortcut) {
    // PortableText: "Ctrl+Shift+N" whatever the platform, rather than "⌘⇧N". Only
    // a sequence's first chord: a menu shows one.
    QString text = QKeySequence(shortcut).toString(QKeySequence::PortableText).section(", ", 0, 0);
    if (text.isEmpty()) return QString();
    if (text.endsWith("++")) text.replace(text.size() - 1, 1, "Plus");   // "Ctrl++"
    QStringList out;
    for (const QString &part : text.split('+', Qt::SkipEmptyParts)) {
        if (part == "Ctrl") out << "Cmd";
        else if (part == "Meta") out << "Ctrl";
        else out << part;
    }
    return out.join('+');
}

} // namespace hm
