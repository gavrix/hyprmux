#include "Files.h"

#include "../Host.h"

#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QSaveFile>
#include <QtQml/QJSEngine>

namespace hm {

Files *Files::create(QQmlEngine *, QJSEngine *) {
    static Files *files = new Files(nullptr);
    QJSEngine::setObjectOwnership(files, QJSEngine::CppOwnership);
    return files;
}

static QString path(const QUrl &u) { return u.isLocalFile() ? u.toLocalFile() : u.toString(); }

QString Files::readText(const QUrl &file) {
    QFile f(path(file));
    if (!f.open(QIODevice::ReadOnly)) { fail(f.errorString()); return QString(); }
    fail(QString());
    return QString::fromUtf8(f.readAll());
}

bool Files::writeText(const QUrl &file, const QString &text) {
    // Written aside and moved into place: a failed write leaves the old file.
    QSaveFile f(path(file));
    if (!f.open(QIODevice::WriteOnly) || f.write(text.toUtf8()) < 0 || !f.commit()) {
        fail(f.errorString());
        return false;
    }
    fail(QString());
    return true;
}

bool Files::exists(const QUrl &file) const { return QFileInfo::exists(path(file)); }

} // namespace hm
